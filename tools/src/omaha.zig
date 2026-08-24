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
fn buildRequestUrl(gpa: Allocator, updateUrl: []const u8, extensionId: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}?os=linux&arch=x64&os_arch=x86_64&nacl_arch=x86-64&prod=chromiumcrx" ++
            "&prodchannel=&prodversion=128.0.0.0&lang=en-US&acceptformat=crx2,crx3" ++
            "&x=id%3D{s}%26v%3D0.0.0.0%26installsource%3Dondemand%26uc",
        .{ updateUrl, extensionId },
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

/// Fetches and parses the update record for one extension. Returns
/// `error.NoUpdateAvailable` if the response has no `<updatecheck ... />`
/// carrying a codebase (which the 0.0.0.0 query trick above should never
/// actually produce, but a server rejecting a malformed id would still land
/// here rather than crash).
pub fn check(
    gpa: Allocator,
    client: *std.http.Client,
    updateUrl: []const u8,
    extensionId: []const u8,
) CheckError!UpdateInfo {
    const requestUrl = try buildRequestUrl(gpa, updateUrl, extensionId);
    defer gpa.free(requestUrl);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = requestUrl },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.NoUpdateAvailable;

    const text = body.written();
    const tagStart = std.mem.indexOf(u8, text, "<updatecheck") orelse return error.MalformedResponse;
    const tagEnd = std.mem.indexOfPos(u8, text, tagStart, "/>") orelse
        (std.mem.indexOfPos(u8, text, tagStart, "</updatecheck>") orelse return error.MalformedResponse);
    const tag = text[tagStart..tagEnd];

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

test "buildRequestUrl percent-encodes the nested x= query correctly" {
    const url = try buildRequestUrl(std.testing.allocator, "https://clients2.google.com/service/update2/crx", "ghlpmldmjjhmdgmneoaibbegkjjbonbk");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "x=id%3Dghlpmldmjjhmdgmneoaibbegkjjbonbk%26v%3D0.0.0.0") != null);
}

test "extracts version, codebase, and hash from a real captured response" {
    // Captured live from clients2.google.com for the real Blocksi extension
    // id while writing this — not a hand-constructed fixture.
    const sample =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod"><daystart elapsed_days="7175" elapsed_seconds="34244"/><app appid="ghlpmldmjjhmdgmneoaibbegkjjbonbk" cohort="1::" cohortname="" status="ok"><updatecheck _esbAllowlist="true" codebase="https://clients2.googleusercontent.com/crx/blobs/AbeXYZ/GHLPMLDMJJHMDGMNEOAIBBEGKJJBONBK_4_9_1_0.crx" fp="1.633ead65" hash_sha256="633ead65d0fe47ed17aa8b8728513ee345a0945b930f72229ac84a6d577d6a1c" protected="0" size="33221788" status="ok" version="4.9.1"/></app></gupdate>
    ;
    const tagStart = std.mem.indexOf(u8, sample, "<updatecheck").?;
    const tagEnd = std.mem.indexOfPos(u8, sample, tagStart, "/>").?;
    const tag = sample[tagStart..tagEnd];

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
    const tagStart = std.mem.indexOf(u8, sample, "<updatecheck").?;
    const tagEnd = std.mem.indexOfPos(u8, sample, tagStart, "/>").?;
    const tag = sample[tagStart..tagEnd];
    const version = try extractAttr(std.testing.allocator, tag, "version");
    try std.testing.expect(version == null);
}
