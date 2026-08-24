//! `check --civil-dir <path>`
//!
//! Run from the repository root. Reads `extensions.json`, checks each
//! tracked extension's update server for a newer version, and for anything
//! that moved: downloads it, deobfuscates the changed files, diffs them
//! against the last snapshot, and scans the diff for signatures pulled from
//! `<civil-dir>/misc/filters/`. Rewrites `extensions.json` with any new
//! versions and `CHANGES_NEEDED.md` with any patch findings.
//!
//! There is no separate "bootstrap" command. The task that asked for this
//! described a first run that only downloads extensions, followed by a
//! recurring three-step check — but `patchDetect.checkOne` already behaves
//! correctly the first time it sees an extension: no prior snapshot means
//! nothing to diff, so it records the current version and leaves signature
//! scanning to the next check, once there's an actual change to compare.
//! That's exactly what a first run needs, so one code path covers both
//! instead of maintaining two that would do nearly identical work.

const std = @import("std");
const Io = std.Io;
const patchDetect = @import("patchDetect.zig");
const signatures = @import("signatures.zig");
const ExtensionRecord = patchDetect.ExtensionRecord;

const EXTENSIONS_JSON = "extensions.json";
const CHANGES_FILE = "CHANGES_NEEDED.md";
const SNAPSHOTS_DIR = "extensions";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var civilDir: ?[]const u8 = null;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    var sawCheck = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) {
            sawCheck = true;
        } else if (std.mem.eql(u8, arg, "--civil-dir")) {
            civilDir = args.next() orelse return fail(io, "missing path after --civil-dir\n");
        }
    }
    if (!sawCheck or civilDir == null) {
        try Io.File.stderr().writeStreamingAll(io, "usage: main check --civil-dir <path-to-civil-checkout>\n");
        return 2;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Scoped to this one file, not the whole misc/filters tree — see the doc
    // comment on signatures.collect for why: the per-vendor middleware files
    // are mostly ordinary HTTP client code whose incidental vocabulary
    // (content types, param names, a vendor's own category labels) produced
    // real false positives when tried, confirmed against actual output.
    // filterBlockerMiddleware.ts is the file that's actually Civil's own
    // identity — the domains it blocks, the headers/events it defines.
    const middlewarePath = try std.fmt.allocPrint(a, "{s}/misc/filters/filterBlockerMiddleware.ts", .{civilDir.?});
    const sigs = signatures.collectFromFile(a, io, middlewarePath) catch |err| {
        return fail(io, try std.fmt.allocPrint(a, "reading Civil filter signatures from {s}: {t}\n", .{ middlewarePath, err }));
    };
    {
        var buf: [128]u8 = undefined;
        try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&buf, "loaded {d} signatures from {s}\n", .{ sigs.items.len, middlewarePath }));
    }

    const recordsJson = try Io.Dir.cwd().readFileAlloc(io, EXTENSIONS_JSON, a, .limited(4 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice([]ExtensionRecord, a, recordsJson, .{ .ignore_unknown_fields = true });
    const records = parsed.value;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var changes = try loadChangesSections(a, io);

    for (records, 0..) |*record, i| {
        var lineBuf: [256]u8 = undefined;
        try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&lineBuf, "[{d}/{d}] {s}: ", .{ i + 1, records.len, record.folder }));

        const baseline = try std.fmt.allocPrint(a, "{s}/{s}/deobfuscated", .{ SNAPSHOTS_DIR, record.folder });
        const scratch = try std.fmt.allocPrint(a, "{s}/{s}/.scratch", .{ SNAPSHOTS_DIR, record.folder });

        const outcome = patchDetect.checkOne(a, io, &client, record.*, sigs.items, .{ .baseline = baseline, .scratch = scratch }) catch |err| {
            try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&lineBuf, "error: {t}\n", .{err}));
            continue;
        };

        switch (outcome) {
            .skipped => |reason| try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&lineBuf, "skipped ({s})\n", .{reason})),
            .upToDate => try Io.File.stdout().writeStreamingAll(io, "up to date\n"),
            .updatedClean => |u| {
                try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&lineBuf, "updated to {s}, clean\n", .{u.newVersion}));
                record.version = u.newVersion;
                _ = changes.remove(record.folder);
            },
            .updatedPatched => |u| {
                try Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&lineBuf, "updated to {s}, PATCHED ({d} hit(s))\n", .{ u.newVersion, u.hits.len }));
                record.version = u.newVersion;
                try changes.put(a, record.folder, try renderSection(a, record.*, u.newVersion, u.hits));
            },
        }
    }

    const outJson = try std.json.Stringify.valueAlloc(a, records, .{ .whitespace = .indent_4 });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = EXTENSIONS_JSON, .data = outJson });

    try writeChangesFile(a, io, changes);

    return 0;
}

fn fail(io: Io, message: []const u8) u8 {
    Io.File.stderr().writeStreamingAll(io, message) catch {};
    return 1;
}

/// Renders one extension's CHANGES_NEEDED.md section. Wrapped in HTML-comment
/// anchors so the next run can find and replace or remove exactly this
/// section without disturbing anyone else's — see loadChangesSections.
fn renderSection(a: std.mem.Allocator, record: ExtensionRecord, newVersion: []const u8, hits: []const patchDetect.SignatureHit) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("<!-- filter:{s} -->\n", .{record.folder});
    try w.print("## {s}\n\n", .{record.name});
    try w.print(
        "The filter {s}'s developers made changes that you need to fix in Civil Proxy. " ++
            "Detected on update to version {s}.\n\n",
        .{ record.name, newVersion },
    );
    for (hits) |hit| {
        try w.print(
            "- `{s}:{d}` matched Civil's own signature `{s}`:\n  ```diff\n  {s}\n  ```\n",
            .{ hit.file, hit.line, hit.signature, hit.diffLine },
        );
    }
    try w.print("<!-- /filter:{s} -->\n", .{record.folder});
    return out.toOwnedSlice();
}

fn loadChangesSections(a: std.mem.Allocator, io: Io) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const text = Io.Dir.cwd().readFileAlloc(io, CHANGES_FILE, a, .limited(4 * 1024 * 1024)) catch return map;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "<!-- filter:")) |start| {
        const idStart = start + "<!-- filter:".len;
        const idEnd = std.mem.indexOfScalarPos(u8, text, idStart, ' ') orelse break;
        const folder = text[idStart .. idEnd - 1]; // trim the trailing " -->"
        const endMarker = try std.fmt.allocPrint(a, "<!-- /filter:{s} -->", .{folder});
        const end = std.mem.indexOfPos(u8, text, start, endMarker) orelse break;
        const sectionEnd = end + endMarker.len;
        try map.put(a, folder, text[start..sectionEnd]);
        pos = sectionEnd;
    }
    return map;
}

fn writeChangesFile(a: std.mem.Allocator, io: Io, changes: std.StringHashMapUnmanaged([]const u8)) !void {
    if (changes.count() == 0) {
        Io.Dir.cwd().deleteFile(io, CHANGES_FILE) catch {};
        return;
    }

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\# Changes needed
        \\
        \\Generated by `tools/`. Each section below is a filter vendor whose latest
        \\release touched something Civil Proxy's own source recognises as its own —
        \\a domain, a header name, an internal event name. That is a real, specific
        \\signal that the vendor is now reacting to Civil, not a guess. A section
        \\disappears on its own once a later release no longer trips the signature
        \\that flagged it.
        \\
        \\
    );

    var it = changes.iterator();
    while (it.next()) |entry| {
        try w.writeAll(entry.value_ptr.*);
        try w.writeAll("\n\n");
    }

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = CHANGES_FILE, .data = out.written() });
}
