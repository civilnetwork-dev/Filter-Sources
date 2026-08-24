//! Chrome's extension autoupdate protocol (nicknamed Omaha after the Google
//! internal project). Every `update_url` in a Chrome manifest — Google's own
//! `clients2.google.com/service/update2/crx` or a vendor's private endpoint
//! like the ones in ../../extensions.json — answers the same GET request
//! shape with the same XML response shape; only the host differs.
//!
//! Verified against the real endpoint while writing this
//! (`clients2.google.com/service/update2/crx` for Blocksi's real id):
//!
//! ```xml
//! <gupdate ...><app appid="..." status="ok">
//!   <updatecheck codebase="https://.../X.crx" version="4.9.1"
//!                hash_sha256="..." size="..." status="ok"/>
//! </app></gupdate>
//! ```
//!
//! The query always asks with a deliberately ancient local version
//! (`v=0.0.0.0`) rather than the version this tool actually has on record.
//! Passing the real local version turns out to matter to the server: asking
//! with a version that's already current gets back a bare
//! `<updatecheck status="noupdate"/>` with no `codebase`/`version` attributes
//! at all (confirmed live). Asking with 0.0.0.0 always gets the full record
//! back, and the *local* comparison against the recorded version (see
//! version.zig) is what actually decides whether anything changed — matching
//! the task's own ordering: fetch what's published, then compare.
//!
//! `prodversion` — the Chrome version this request claims to come from — is
//! fetched dynamically from Google's own Chrome Version History API rather
//! than hardcoded. A hardcoded value goes stale by construction: this file
//! originally shipped with `128.0.0.0`, and by the time this comment was
//! written the real current stable was `151.0.7922.173` (confirmed live
//! against `versionhistory.googleapis.com`) — over twenty major versions
//! off. Nothing observed in this file's responses actually *depends* on
//! `prodversion` being current (Google's server answered correctly even
//! carrying the stale value), but claiming a Chrome version over a year old
//! is the kind of detail that's cheap to keep honest and easy to forget.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const UpdateInfo = struct {
    version: []u8,
    codebase: []u8,
    hashSha256: ?[]u8,

    pub fn deinit(self: UpdateInfo, gpa: Allocator) void {
        gpa.free(self.version);
        gpa.free(self.codebase);
        if (self.hashSha256) |h| gpa.free(h);
    }
};

pub const CheckError = error{
    NoUpdateAvailable,
    MalformedResponse,
} || Allocator.Error || std.http.Client.FetchError || std.Uri.ParseError;

/// The query string Chrome itself sends, percent-encoded exactly as Chrome
/// encodes it (the `x=` param's *value* is itself a second query string,
/// percent-encoded once more so it survives as one opaque param).
fn buildRequestUrl(
    gpa: Allocator,
    updateUrl: []const u8,
    extensionId: []const u8,
    chromeVersion: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}?os=linux&arch=x64&os_arch=x86_64&nacl_arch=x86-64&prod=chromiumcrx" ++
            "&prodchannel=&prodversion={s}&lang=en-US&acceptformat=crx2,crx3" ++
            "&x=id%3D{s}%26v%3D0.0.0.0%26installsource%3Dondemand%26uc",
        .{ updateUrl, chromeVersion, extensionId },
    );
}

/// Pulls `name="value"` out of a tag's attribute text. Not a general XML
/// parser — the response is one small, fixed, well-known tag shape (verified
/// live above), and reaching for a full XML parser to read four attributes
/// off one element would be more code and more trust surface than this.
fn extractAttr(gpa: Allocator, tag: []const u8, name: []const u8) Allocator.Error!?[]u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, tag, needle) orelse return null) + needle.len;
    const rest = tag[start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return try gpa.dupe(u8, rest[0..end]);
}

/// Finds the `<updatecheck ... />` tag that belongs to `<app appid="{id}">`
/// specifically, and returns its attribute text (borrowed from `text`).
///
/// Google's real Omaha server answers a query for one id with a response
/// about that one id, so a document-wide "first `<updatecheck>`" search
/// would be enough there. It isn't enough in general: several vendor
/// endpoints in extensions.json are static files that return their *entire*
/// app catalog regardless of the `x=id=...` query param — confirmed live on
/// both Aristotle's and Securly's shared endpoints, each answering every
/// request (any id, any of their several extensions) with the same
/// multi-`<app>` document. Taking the first `<updatecheck>` in that document
/// silently returns a *different extension's* version and download URL —
/// caught by exactly that: aristotleEducator's first check reported version
/// "18.14.0", which turned out to be aristotleStudent's version, not
/// Educator's own "11.0.0". Scoping the search to the matching `<app appid>`
/// block fixes it for both the single-app and multi-app response shapes.
fn findUpdatecheckForApp(text: []const u8, extensionId: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const appNeedle = std.fmt.bufPrint(&buf, "<app appid=\"{s}\"", .{extensionId}) catch return null;
    const appStart = std.mem.indexOf(u8, text, appNeedle) orelse return null;

    // Bound the search at whichever comes first: this app's own closing tag,
    // or the next sibling `<app` — so a malformed or updatecheck-less entry
    // for the requested id can never fall through into a neighboring app's
    // data instead.
    const afterApp = text[appStart..];
    const ownEnd = std.mem.indexOf(u8, afterApp, "</app>");
    const nextApp = std.mem.indexOfPos(u8, afterApp, appNeedle.len, "<app appid=");
    const boundary = blk: {
        if (ownEnd) |a| {
            if (nextApp) |b| break :blk @min(a, b);
            break :blk a;
        }
        break :blk nextApp orelse afterApp.len;
    };
    const scoped = afterApp[0..boundary];

    const tagStart = std.mem.indexOf(u8, scoped, "<updatecheck") orelse return null;
    const tagEnd = std.mem.indexOfPos(u8, scoped, tagStart, "/>") orelse
        (std.mem.indexOfPos(u8, scoped, tagStart, "</updatecheck>") orelse return null);
    return scoped[tagStart..tagEnd];
}

/// Fetches and parses the update record for one extension. Returns
/// `error.NoUpdateAvailable` if the response has no `<app appid="...">`
/// matching the requested id, or that app has no `<updatecheck ... />`
/// carrying a codebase.
pub fn check(
    gpa: Allocator,
    client: *std.http.Client,
    updateUrl: []const u8,
    extensionId: []const u8,
    chromeVersion: []const u8,
) CheckError!UpdateInfo {
    const requestUrl = try buildRequestUrl(gpa, updateUrl, extensionId, chromeVersion);
    defer gpa.free(requestUrl);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = requestUrl },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.NoUpdateAvailable;

    const text = body.written();
    const tag = findUpdatecheckForApp(text, extensionId) orelse return error.NoUpdateAvailable;

    const version = try extractAttr(gpa, tag, "version") orelse return error.NoUpdateAvailable;
    errdefer gpa.free(version);
    const codebase = try extractAttr(gpa, tag, "codebase") orelse {
        gpa.free(version);
        return error.NoUpdateAvailable;
    };
    errdefer gpa.free(codebase);
    const hash = try extractAttr(gpa, tag, "hash_sha256");

    return .{ .version = version, .codebase = codebase, .hashSha256 = hash };
}

const CHROME_VERSION_API =
    "https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/stable/versions?pageSize=1";

/// Hardcoded floor used only if the live lookup fails (network hiccup, API
/// shape change) — see `fetchLatestChromeVersion`. Not meant to stay current;
/// meant to keep the tool working on a bad day without guessing wrong.
const FALLBACK_CHROME_VERSION = "128.0.0.0";

/// The JSON body's shape (only the piece this needs):
/// `{"versions":[{"name":"...","version":"151.0.7922.173"}],"nextPageToken":"..."}`.
/// Split from `fetchLatestChromeVersion` so the parsing itself is testable
/// against a real captured response without a network call.
fn parseLatestVersion(gpa: Allocator, json: []const u8) !?[]u8 {
    const Response = struct { versions: []struct { version: []const u8 } };
    var parsed = std.json.parseFromSlice(Response, gpa, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.versions.len == 0) return null;
    return try gpa.dupe(u8, parsed.value.versions[0].version);
}

/// Queries Google's official Chrome Version History API
/// (https://developer.chrome.com/docs/web-platform/chrome-versionhistory)
/// for the current stable Linux Chrome version. Verified live while writing
/// this — see the module doc comment for the actual numbers.
///
/// Falls back to `FALLBACK_CHROME_VERSION` on any failure (network,
/// unexpected response shape) instead of failing the whole run: nothing
/// this tool has observed actually depends on `prodversion` being current
/// (see `check`'s doc comment), so a lookup failure here should degrade,
/// not abort a check of 28 extensions over one cosmetic field.
pub fn fetchLatestChromeVersion(gpa: Allocator, client: *std.http.Client) Allocator.Error![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = CHROME_VERSION_API },
        .response_writer = &body.writer,
    }) catch return gpa.dupe(u8, FALLBACK_CHROME_VERSION);
    if (result.status != .ok) return gpa.dupe(u8, FALLBACK_CHROME_VERSION);

    return (parseLatestVersion(gpa, body.written()) catch null) orelse
        try gpa.dupe(u8, FALLBACK_CHROME_VERSION);
}

test "buildRequestUrl threads the given Chrome version through, not a hardcoded one" {
    const url = try buildRequestUrl(
        std.testing.allocator,
        "https://clients2.google.com/service/update2/crx",
        "ghlpmldmjjhmdgmneoaibbegkjjbonbk",
        "151.0.7922.173",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "prodversion=151.0.7922.173") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "128.0.0.0") == null);
}

test "buildRequestUrl percent-encodes the nested x= query correctly" {
    const url = try buildRequestUrl(
        std.testing.allocator,
        "https://clients2.google.com/service/update2/crx",
        "ghlpmldmjjhmdgmneoaibbegkjjbonbk",
        "151.0.0.0",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "x=id%3Dghlpmldmjjhmdgmneoaibbegkjjbonbk%26v%3D0.0.0.0") != null);
}

test "extracts version, codebase, and hash from a real captured response" {
    // Captured live from clients2.google.com for the real Blocksi extension
    // id while writing this — not a hand-constructed fixture.
    const sample =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod"><daystart elapsed_days="7175" elapsed_seconds="34244"/><app appid="ghlpmldmjjhmdgmneoaibbegkjjbonbk" cohort="1::" cohortname="" status="ok"><updatecheck _esbAllowlist="true" codebase="https://clients2.googleusercontent.com/crx/blobs/AbeXYZ/GHLPMLDMJJHMDGMNEOAIBBEGKJJBONBK_4_9_1_0.crx" fp="1.633ead65" hash_sha256="633ead65d0fe47ed17aa8b8728513ee345a0945b930f72229ac84a6d577d6a1c" protected="0" size="33221788" status="ok" version="4.9.1"/></app></gupdate>
    ;
    const tag = findUpdatecheckForApp(sample, "ghlpmldmjjhmdgmneoaibbegkjjbonbk").?;

    const version = (try extractAttr(std.testing.allocator, tag, "version")).?;
    defer std.testing.allocator.free(version);
    const codebase = (try extractAttr(std.testing.allocator, tag, "codebase")).?;
    defer std.testing.allocator.free(codebase);
    const hash = (try extractAttr(std.testing.allocator, tag, "hash_sha256")).?;
    defer std.testing.allocator.free(hash);

    try std.testing.expectEqualStrings("4.9.1", version);
    try std.testing.expect(std.mem.startsWith(u8, codebase, "https://clients2.googleusercontent.com/"));
    try std.testing.expectEqualStrings("633ead65d0fe47ed17aa8b8728513ee345a0945b930f72229ac84a6d577d6a1c", hash);
}

test "a bare noupdate response with no codebase yields NoUpdateAvailable, not a crash" {
    // Also captured live: this is what the server sends when the queried
    // version is already current.
    const sample =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod"><app appid="x" status="ok"><updatecheck _esbAllowlist="true" status="noupdate"/></app></gupdate>
    ;
    const tag = findUpdatecheckForApp(sample, "x").?;
    const version = try extractAttr(std.testing.allocator, tag, "version");
    try std.testing.expect(version == null);
}

test "an unknown appid not present in the response yields null, not a crash" {
    const sample =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0"><app appid="x"><updatecheck version="1.0" codebase="https://e/x.crx"/></app></gupdate>
    ;
    try std.testing.expect(findUpdatecheckForApp(sample, "does-not-exist") == null);
}

test "a multi-app static manifest returns the requested app's own updatecheck, not the first one in the document" {
    // Captured live from rogueone.aristotleinsight.com while writing this —
    // the actual regression this test exists for. The server ignores the
    // `x=id=...` query param entirely and always returns its full 3-app
    // catalog; a document-wide "first <updatecheck>" search silently picked
    // up the Student MV2 build's version (18.14.0) when checking the
    // Educator extension, whose real version at capture time was 11.0.0.
    const sample =
        \\<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
        \\<app appid="lehdheafjemnomjkncejplognngbabho"><updatecheck codebase="https://rogueone.aristotleinsight.com/Student/Download/x" version="18.14.0" /></app><app appid="mjkknmkfafjbnhndgpnjmkbfkiobcahh"><updatecheck codebase="https://rogueone.aristotleinsight.com/Educator/Download/y" version="11.0.0" /></app><app appid="eljeiokhajcnnpgegbcablegmaipigdk"><updatecheck codebase="https://rogueone.aristotleinsight.com/MV3/Student/Download/z" version="23.14.0" /></app></gupdate>
    ;

    const educator = findUpdatecheckForApp(sample, "mjkknmkfafjbnhndgpnjmkbfkiobcahh").?;
    const educatorVersion = (try extractAttr(std.testing.allocator, educator, "version")).?;
    defer std.testing.allocator.free(educatorVersion);
    try std.testing.expectEqualStrings("11.0.0", educatorVersion);

    // And the app listed *first* in the document is still reachable by its
    // own id — this isn't "always return the second app," it's "return the
    // one that was actually asked for."
    const student = findUpdatecheckForApp(sample, "lehdheafjemnomjkncejplognngbabho").?;
    const studentVersion = (try extractAttr(std.testing.allocator, student, "version")).?;
    defer std.testing.allocator.free(studentVersion);
    try std.testing.expectEqualStrings("18.14.0", studentVersion);

    const mv3Student = findUpdatecheckForApp(sample, "eljeiokhajcnnpgegbcablegmaipigdk").?;
    const mv3Version = (try extractAttr(std.testing.allocator, mv3Student, "version")).?;
    defer std.testing.allocator.free(mv3Version);
    try std.testing.expectEqualStrings("23.14.0", mv3Version);
}

test "parses the latest version from a real captured versionhistory.googleapis.com response" {
    // Captured live from versionhistory.googleapis.com?pageSize=1 while
    // writing this.
    const sample =
        \\{
        \\  "versions": [
        \\    {
        \\      "name": "chrome/platforms/linux/channels/stable/versions/151.0.7922.173",
        \\      "version": "151.0.7922.173"
        \\    }
        \\  ],
        \\  "nextPageToken": "226156535"
        \\}
    ;
    const version = (try parseLatestVersion(std.testing.allocator, sample)).?;
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("151.0.7922.173", version);
}

test "parseLatestVersion degrades to null on garbage input instead of erroring" {
    const notJson = try parseLatestVersion(std.testing.allocator, "not json at all");
    try std.testing.expect(notJson == null);

    const emptyVersions = (try parseLatestVersion(std.testing.allocator, "{\"versions\":[]}"));
    try std.testing.expect(emptyVersions == null);

    const wrongShape = try parseLatestVersion(std.testing.allocator, "{\"unrelated\":true}");
    try std.testing.expect(wrongShape == null);
}
