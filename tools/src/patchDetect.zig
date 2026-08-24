//! Orchestrates one full check cycle: for each tracked extension, ask its
//! update server what's current (omaha.zig), compare against what's recorded
//! (version.zig), and if it moved, download + deobfuscate the new version
//! (crx.zig, deobfuscator.zig), diff it against the last known-good snapshot,
//! and scan the diff for signatures pulled from Civil's own filter source
//! (signatures.zig). `main.zig` wires this to the CLI and to CHANGES_NEEDED.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const omaha = @import("omaha.zig");
const crx = @import("crx.zig");
const deobfuscator = @import("deobfuscator.zig");
const version = @import("version.zig");
const signatures = @import("signatures.zig");

pub const ExtensionRecord = struct {
    folder: []const u8,
    name: []const u8,
    id: ?[]const u8 = null,
    version: []const u8 = "",
    updateUrl: ?[]const u8 = null,
    manifestVersion: ?u8 = null,
};

pub const SignatureHit = struct {
    file: []const u8,
    line: u32,
    signature: []const u8,
    /// The single added (`+`) diff line the signature was found on, for the
    /// human-readable report — enough context to see what changed without
    /// dumping the whole file into CHANGES_NEEDED.md.
    diffLine: []const u8,
};

pub const CheckOutcome = union(enum) {
    /// No `id`/`updateUrl` on record — can't query an update server without
    /// them (see extensions.json: 7 of 28 vendors use a private endpoint
    /// this tool hasn't resolved an id for yet).
    skipped: []const u8,
    upToDate,
    /// Version moved but nothing in the new code touched a Civil signature.
    updatedClean: struct { newVersion: []u8 },
    /// Version moved and the new code touched at least one Civil signature.
    updatedPatched: struct { newVersion: []u8, hits: []SignatureHit },
};

/// Scans a unified diff's added lines (`+`, excluding the `+++` file header)
/// for occurrences of any known signature. Pure and separately tested: this
/// is the actual "did the vendor patch against Civil" decision, everything
/// else in this file is plumbing to get a diff in front of it.
pub fn scanDiffForSignatures(
    gpa: Allocator,
    diffText: []const u8,
    sigs: []const signatures.Signature,
    fileLabel: []const u8,
) Allocator.Error![]SignatureHit {
    var hits: std.ArrayList(SignatureHit) = .empty;
    errdefer hits.deinit(gpa);

    var lines = std.mem.splitScalar(u8, diffText, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '+') continue;
        if (std.mem.startsWith(u8, line, "+++")) continue;
        const added = line[1..];

        for (sigs) |sig| {
            if (std.mem.indexOf(u8, added, sig.text) == null) continue;
            try hits.append(gpa, .{
                .file = fileLabel,
                .line = sig.line,
                .signature = sig.text,
                .diffLine = try gpa.dupe(u8, added),
            });
        }
    }
    return hits.toOwnedSlice(gpa);
}

/// Runs `git diff --no-index` between two files and returns its stdout.
/// Exit code 1 (differences found) is the expected, successful case for
/// `--no-index` — only 2+ (a real git error) is treated as failure.
pub fn diffFiles(gpa: Allocator, io: Io, oldPath: []const u8, newPath: []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "diff", "--no-index", "--unified=3", oldPath, newPath },
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| {
            if (code >= 2) return error.GitDiffFailed;
        },
        else => return error.GitDiffFailed,
    }
    return result.stdout;
}

/// Deobfuscates every `.js`/`.tmp` file under `dir` into `outDir`, mirroring
/// relative paths. Returns nothing — callers walk `outDir` themselves to
/// compare against a previous baseline, since "what changed" is a
/// tree-diffing question, not something this function needs an opinion on.
fn deobfuscateTree(gpa: Allocator, io: Io, srcDir: Io.Dir, outDir: Io.Dir) !void {
    var walker = try srcDir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const isJs = std.mem.endsWith(u8, entry.path, ".js") or std.mem.endsWith(u8, entry.path, ".tmp");
        if (!isJs) continue;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(32 * 1024 * 1024)) catch continue;
        defer gpa.free(source);

        const result = deobfuscator.deobfuscate(gpa, source, .{}) catch continue; // not valid JS — skip, don't abort the tree
        defer result.deinit(gpa);

        if (std.fs.path.dirname(entry.path)) |parent| {
            try outDir.createDirPath(io, parent);
        }
        try outDir.writeFile(io, .{ .sub_path = entry.path, .data = result.code });
    }
}

/// One extension's full check cycle. `paths.baseline` is where the previous
/// run's deobfuscated snapshot lives (created if this is the first check);
/// `paths.scratch` is a working directory this function owns completely
/// (created fresh, and left in place afterward holding the new baseline —
/// the caller is expected to have already removed anything stale there).
pub fn checkOne(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    record: ExtensionRecord,
    sigs: []const signatures.Signature,
    /// Fetched once per run by the caller (see main.zig), not once per
    /// extension — it's the same value for every Omaha query in a run, and
    /// re-fetching it 28 times would just be 27 wasted requests.
    chromeVersion: []const u8,
    paths: struct { baseline: []const u8, scratch: []const u8 },
) !CheckOutcome {
    const id = record.id orelse return .{ .skipped = "no known extension id" };
    const updateUrl = record.updateUrl orelse return .{ .skipped = "no update_url on record" };

    const info = omaha.check(gpa, client, updateUrl, id, chromeVersion) catch |err| switch (err) {
        error.NoUpdateAvailable => return .upToDate,
        else => return err,
    };
    defer info.deinit(gpa);

    if (!version.isNewer(info.version, record.version)) return .upToDate;

    var fetchBody: std.Io.Writer.Allocating = .init(gpa);
    defer fetchBody.deinit();
    const fetchResult = try client.fetch(.{
        .location = .{ .url = info.codebase },
        .response_writer = &fetchBody.writer,
    });
    if (fetchResult.status != .ok) return error.DownloadFailed;
    const crxBytes = fetchBody.written();

    if (info.hashSha256) |expected| {
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(crxBytes, &actual, .{});
        var actualHex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&actualHex, "{x}", .{actual}) catch unreachable;
        if (!std.ascii.eqlIgnoreCase(&actualHex, expected)) return error.DownloadHashMismatch;
    }

    try Io.Dir.cwd().createDirPath(io, paths.scratch);
    var unpackDir = try Io.Dir.cwd().openDir(io, paths.scratch, .{ .iterate = true });
    defer unpackDir.close(io);

    var zipScratchBuf: [512]u8 = undefined;
    const zipScratchPath = try std.fmt.bufPrint(&zipScratchBuf, "{s}.download.zip", .{paths.scratch});
    try crx.extract(io, crxBytes, unpackDir, zipScratchPath);

    const newBaseline = try std.fmt.allocPrint(gpa, "{s}.new", .{paths.baseline});
    defer gpa.free(newBaseline);
    Io.Dir.cwd().deleteTree(io, newBaseline) catch {};
    try Io.Dir.cwd().createDirPath(io, newBaseline);
    var newBaselineDir = try Io.Dir.cwd().openDir(io, newBaseline, .{ .iterate = true });
    defer newBaselineDir.close(io);

    try deobfuscateTree(gpa, io, unpackDir, newBaselineDir);

    var hits: std.ArrayList(SignatureHit) = .empty;
    errdefer hits.deinit(gpa);

    // Signature scanning only ever runs on a *diff* — never on a file's full
    // content. A vendor's own extension legitimately references its own
    // domain throughout its own code; scanning a whole file the first time
    // it's seen (whether that's the extension's very first check, or a file
    // that's simply new in this version) flags that ordinary self-reference
    // as if it were new "reaction to Civil," which it isn't — confirmed by
    // an actual run: Blocksi's first-ever check flagged `blocksi.net` in
    // five files, every one of them just the extension talking to its own
    // domain, before this restriction was added. A file with nothing to
    // diff against is added to the baseline and left unscanned; it becomes
    // eligible for real detection on the *next* check, once there's an
    // actual change to compare.
    var walker = try newBaselineDir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const fileLabel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ record.folder, entry.path });
        // fileLabel is intentionally leaked into any hits that reference it
        // (freed together with the arena the caller wraps this whole check
        // in — see main.zig) rather than reference-counted here.

        const oldPath = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ paths.baseline, entry.path });
        defer gpa.free(oldPath);
        const newPath = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ newBaseline, entry.path });
        defer gpa.free(newPath);

        if (Io.Dir.cwd().access(io, oldPath, .{})) {
            const diffText = diffFiles(gpa, io, oldPath, newPath) catch continue;
            defer gpa.free(diffText);
            if (diffText.len == 0) continue; // identical — git diff produced nothing

            const fileHits = try scanDiffForSignatures(gpa, diffText, sigs, fileLabel);
            defer gpa.free(fileHits);
            try hits.appendSlice(gpa, fileHits);
        } else |_| {
            continue; // no prior version of this file to diff against yet
        }
    }

    // The new snapshot becomes the baseline for next time, whether or not
    // anything was flagged — the task calls for this "regardless of whether
    // how much is patched or even if nothing is patched."
    Io.Dir.cwd().deleteTree(io, paths.baseline) catch {};
    try Io.Dir.cwd().rename(newBaseline, Io.Dir.cwd(), paths.baseline, io);
    Io.Dir.cwd().deleteTree(io, paths.scratch) catch {};

    const newVersion = try gpa.dupe(u8, info.version);
    if (hits.items.len == 0) {
        hits.deinit(gpa);
        return .{ .updatedClean = .{ .newVersion = newVersion } };
    }
    return .{ .updatedPatched = .{ .newVersion = newVersion, .hits = try hits.toOwnedSlice(gpa) } };
}

test "flags a signature that appears on an added line, ignores it on a removed one" {
    const gpa = std.testing.allocator;
    var sigs = [_]signatures.Signature{
        .{ .text = try gpa.dupe(u8, "securly.com"), .file = try gpa.dupe(u8, "filterBlockerMiddleware.ts"), .line = 12 },
    };
    defer for (sigs) |s| s.deinit(gpa);

    const diff =
        \\--- a/background.js
        \\+++ b/background.js
        \\@@ -1,3 +1,3 @@
        \\-fetch("https://old.example/check");
        \\+fetch("https://securly.com/detect-proxy");
        \\ console.log("unchanged");
    ;
    const hits = try scanDiffForSignatures(gpa, diff, &sigs, "background.js");
    defer {
        for (hits) |h| gpa.free(h.diffLine);
        gpa.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("securly.com", hits[0].signature);
    try std.testing.expect(std.mem.indexOf(u8, hits[0].diffLine, "securly.com") != null);
}

test "a signature only on a removed line is not a hit" {
    const gpa = std.testing.allocator;
    var sigs = [_]signatures.Signature{
        .{ .text = try gpa.dupe(u8, "securly.com"), .file = try gpa.dupe(u8, "x.ts"), .line = 1 },
    };
    defer for (sigs) |s| s.deinit(gpa);

    const diff =
        \\--- a/background.js
        \\+++ b/background.js
        \\-fetch("https://securly.com/old");
        \\+fetch("https://securly.com/new");
    ;
    // securly.com appears on BOTH the removed and added line here — still a
    // real hit, since the vendor's code still references it after the
    // change. The point of this test is the "removed-only" case below.
    const hitsBoth = try scanDiffForSignatures(gpa, diff, &sigs, "x.js");
    defer {
        for (hitsBoth) |h| gpa.free(h.diffLine);
        gpa.free(hitsBoth);
    }
    try std.testing.expectEqual(@as(usize, 1), hitsBoth.len);

    const removedOnly =
        \\--- a/background.js
        \\+++ b/background.js
        \\-fetch("https://securly.com/old");
        \\+fetch("https://totally-unrelated.example/new");
    ;
    const hits = try scanDiffForSignatures(gpa, removedOnly, &sigs, "x.js");
    defer {
        for (hits) |h| gpa.free(h.diffLine);
        gpa.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "the +++ file header line is never itself scanned as an addition" {
    const gpa = std.testing.allocator;
    var sigs = [_]signatures.Signature{
        .{ .text = try gpa.dupe(u8, "background.js"), .file = try gpa.dupe(u8, "x.ts"), .line = 1 },
    };
    defer for (sigs) |s| s.deinit(gpa);

    // "background.js" appears in the +++ header itself; that must not count
    // as the vendor's code "adding" a reference to it.
    const diff =
        \\--- a/background.js
        \\+++ b/background.js
        \\ unchanged line
    ;
    const hits = try scanDiffForSignatures(gpa, diff, &sigs, "background.js");
    defer {
        for (hits) |h| gpa.free(h.diffLine);
        gpa.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
