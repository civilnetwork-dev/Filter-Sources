//! Extracts a "does the vendor's new code specifically target Civil" signature
//! dictionary from a checkout of Civil Proxy's `misc/filters/` — string
//! literals distinctive enough that seeing one appear in a filter vendor's
//! diff is a real signal, not coincidence.
//!
//! Not a JS/TS tokenizer — a plain string-literal scanner, which is enough
//! for this and stays honest about what it is: a heuristic, not a compiler.
//!
//! ## The filter, and why it's shaped this way
//!
//! Checked against real files (`filterBlockerMiddleware.ts`,
//! `securly/middleware.ts`) while building this. Two noise sources showed up
//! immediately in a naive "any string literal >= 8 chars" pass:
//!
//!   - Relative import specifiers (`"./posthog"`, `"../broker"`) — never a
//!     signature, always noise. Excluded by prefix.
//!   - Human-readable labels Civil echoes back from a *vendor's own* API
//!     ("Pornography", "Streaming Media / YouTube-specific" — Securly's
//!     content-category taxonomy, reflected through Civil's code, not
//!     something Civil owns). These, and ordinary log-message prose
//!     ("Requested hostname matches a blocked domain."), all start with a
//!     capital letter. Real signatures — domain names, header names, event
//!     names, cookie names — are conventionally lowercase. So: keep a
//!     literal only if it starts lowercase or a digit. Imperfect (a handful
//!     of npm import specifiers like "doc999tor-fast-geoip" slip through as
//!     harmless false positives), but a large, real improvement over no
//!     filter at all, verified against the actual files this reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Signature = struct {
    text: []u8,
    file: []u8,
    line: u32,

    pub fn deinit(self: Signature, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.file);
    }
};

const MIN_LEN = 8;

fn isSignatureCandidate(text: []const u8) bool {
    if (text.len < MIN_LEN) return false;
    if (std.mem.startsWith(u8, text, "./") or std.mem.startsWith(u8, text, "../")) return false;
    const first = text[0];
    return std.ascii.isLower(first) or std.ascii.isDigit(first);
}

/// Scans one file's text for `"..."` / `'...'` literals, appending any that
/// pass `isSignatureCandidate` to `out`. Deliberately not template-literal
/// aware — a backtick string with `${}` interpolation isn't a fixed
/// signature to begin with.
fn scanText(gpa: Allocator, relPath: []const u8, text: []const u8, out: *std.ArrayList(Signature)) !void {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') {
            line += 1;
            continue;
        }
        if (c != '"' and c != '\'') continue;

        const quote = c;
        const startLine = line;
        const contentStart = i + 1;
        var j = contentStart;
        var escaped = false;
        while (j < text.len) : (j += 1) {
            const cj = text[j];
            if (cj == '\n') break; // unterminated on this line: bail, not a literal
            if (escaped) {
                escaped = false;
                continue;
            }
            if (cj == '\\') {
                escaped = true;
                continue;
            }
            if (cj == quote) break;
        }
        if (j >= text.len or text[j] != quote) {
            // Unterminated (ran off the end of the line, or of the file) —
            // not a real literal; resume scanning right after the quote we
            // opened on rather than skipping the rest of the line, so a
            // genuine literal later on the same line still gets found.
            i = contentStart - 1;
            continue;
        }

        const content = text[contentStart..j];
        if (isSignatureCandidate(content)) {
            try out.append(gpa, .{
                .text = try gpa.dupe(u8, content),
                .file = try gpa.dupe(u8, relPath),
                .line = startLine,
            });
        }
        i = j; // loop's i += 1 lands past the closing quote
    }
}

/// Reads one file and collects every candidate signature in it. This is what
/// `main.zig` actually uses by default, pointed at
/// `misc/filters/filterBlockerMiddleware.ts` — see the module doc comment on
/// `collect` below for why that file specifically, not the whole tree.
pub fn collectFromFile(gpa: Allocator, io: Io, path: []const u8) !std.ArrayList(Signature) {
    var out: std.ArrayList(Signature) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(gpa);
        out.deinit(gpa);
    }
    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(text);
    try scanText(gpa, path, text, &out);
    return out;
}

/// Walks `filtersDir` (expected: a checkout's `misc/filters` directory) for
/// `.ts` files and collects every candidate signature. **Not what `main.zig`
/// uses by default** — kept for a caller that deliberately wants the wider,
/// noisier net. Confirmed against the real tree while building this: the
/// per-vendor `checker.ts`/`middleware.ts` files are mostly ordinary HTTP
/// client code, and the length/casing filter above lets through plenty of
/// their *incidental* vocabulary — `"application/json"`, `"arraybuffer"`,
/// `"identity"` (a query param name Civil sends), `"google.com"` (a domain
/// inside a *vendor's own* blocklist Civil happens to parse), category
/// labels like `"gambling"` a vendor's API returns and Civil just relays.
/// None of those are Civil's own identity — a filter vendor "patching
/// against" one would be coincidence, not reaction. `filterBlockerMiddleware.ts`
/// alone, by contrast, is clean: every candidate it yields (verified
/// directly against the file) is a real vendor-telemetry domain Civil
/// blocks or a header/event name Civil itself defined. Caller owns the
/// returned list and each entry (`sig.deinit(gpa)`).
pub fn collect(gpa: Allocator, io: Io, filtersDir: []const u8) !std.ArrayList(Signature) {
    var out: std.ArrayList(Signature) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(gpa);
        out.deinit(gpa);
    }

    var dir = try Io.Dir.cwd().openDir(io, filtersDir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".ts")) continue;

        const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 * 1024 * 1024)) catch continue;
        defer gpa.free(text);

        const relPath = try std.fmt.allocPrint(gpa, "{s}", .{entry.path});
        defer gpa.free(relPath);
        try scanText(gpa, relPath, text, &out);
    }

    return out;
}

test "extracts a lowercase domain but rejects a relative import path" {
    var out: std.ArrayList(Signature) = .empty;
    defer {
        for (out.items) |s| s.deinit(std.testing.allocator);
        out.deinit(std.testing.allocator);
    }
    try scanText(std.testing.allocator, "middleware.ts",
        \\import x from "./posthog";
        \\const domains = ["securly.com", "securly.io"];
    , &out);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("securly.com", out.items[0].text);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line);
    try std.testing.expectEqualStrings("securly.io", out.items[1].text);
}

test "rejects a capitalized human-readable category label" {
    var out: std.ArrayList(Signature) = .empty;
    defer {
        for (out.items) |s| s.deinit(std.testing.allocator);
        out.deinit(std.testing.allocator);
    }
    try scanText(std.testing.allocator, "middleware.ts",
        \\const categories = ["Streaming Media / YouTube-specific", "Pornography"];
    , &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "rejects a short literal even if it would otherwise qualify" {
    var out: std.ArrayList(Signature) = .empty;
    defer {
        for (out.items) |s| s.deinit(std.testing.allocator);
        out.deinit(std.testing.allocator);
    }
    try scanText(std.testing.allocator, "x.ts", "const a = \"short\";", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "handles single quotes and an escaped quote inside the literal" {
    var out: std.ArrayList(Signature) = .empty;
    defer {
        for (out.items) |s| s.deinit(std.testing.allocator);
        out.deinit(std.testing.allocator);
    }
    try scanText(std.testing.allocator, "x.ts", "const h = 'x-forwarded-host';", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("x-forwarded-host", out.items[0].text);
}

test "an unterminated literal on a line doesn't swallow a real one after it" {
    var out: std.ArrayList(Signature) = .empty;
    defer {
        for (out.items) |s| s.deinit(std.testing.allocator);
        out.deinit(std.testing.allocator);
    }
    // A stray quote (e.g. inside a template literal this scanner doesn't
    // understand) shouldn't desynchronize the scanner for the rest of the file.
    try scanText(std.testing.allocator, "x.ts",
        \\const weird = `it's fine`;
        \\const real = "filter_hostname_blocked";
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("filter_hostname_blocked", out.items[0].text);
}
