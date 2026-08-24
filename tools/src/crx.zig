//! Unpacks a downloaded `.crx` (Chrome's signed extension package) into a
//! plain directory of files.
//!
//! A CRX is a small binary header glued onto the front of an ordinary ZIP
//! archive — the header carries the developer's signature over the ZIP,
//! which this tool has no reason to verify (the download already came over
//! TLS from Google's or the vendor's own update server, and `omaha.zig`
//! already carries the server's own `hash_sha256` for integrity checking at
//! the download step). All this needs from the header is where it ends.
//!
//! Header formats (https://chromium.googlesource.com/chromium/src/+/main/components/crx_file/crx3.proto):
//!   CRX2: "Cr24" | version=2 (u32 LE) | pubkey_len (u32 LE) | sig_len (u32 LE) | pubkey | sig | ZIP
//!   CRX3: "Cr24" | version=3 (u32 LE) | header_len (u32 LE) | header (protobuf, skipped) | ZIP

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    NotACrxFile,
    UnsupportedCrxVersion,
    TruncatedHeader,
};

/// Returns the byte offset in `crx` where the embedded ZIP archive begins.
pub fn zipOffset(crx: []const u8) (Error)!usize {
    if (crx.len < 12 or !std.mem.eql(u8, crx[0..4], "Cr24")) return error.NotACrxFile;
    const version = std.mem.readInt(u32, crx[4..8], .little);
    switch (version) {
        2 => {
            if (crx.len < 16) return error.TruncatedHeader;
            const pubkeyLen = std.mem.readInt(u32, crx[8..12], .little);
            const sigLen = std.mem.readInt(u32, crx[12..16], .little);
            const offset = 16 + @as(usize, pubkeyLen) + @as(usize, sigLen);
            if (crx.len < offset) return error.TruncatedHeader;
            return offset;
        },
        3 => {
            const headerLen = std.mem.readInt(u32, crx[8..12], .little);
            const offset = 12 + @as(usize, headerLen);
            if (crx.len < offset) return error.TruncatedHeader;
            return offset;
        },
        else => return error.UnsupportedCrxVersion,
    }
}

/// Extracts a CRX's contents into `destDir`, which must already exist.
/// `scratchZipPath` is a path (relative to `destDir`'s parent, i.e. any path
/// this process can write to) for a temporary `.zip` file — `std.zip.extract`
/// wants a real seekable file, and the simplest reliable way to hand it "the
/// ZIP part of this CRX" is to write just that part out fresh rather than try
/// to make a sub-range reader over the in-memory CRX bytes.
pub fn extract(
    io: Io,
    crx: []const u8,
    destDir: Io.Dir,
    scratchZipPath: []const u8,
) !void {
    const offset = try zipOffset(crx);
    const zipBytes = crx[offset..];

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = scratchZipPath, .data = zipBytes });
    defer Io.Dir.cwd().deleteFile(io, scratchZipPath) catch {};

    var zipFile = try Io.Dir.cwd().openFile(io, scratchZipPath, .{});
    defer zipFile.close(io);

    var readBuf: [4096]u8 = undefined;
    var reader = zipFile.reader(io, &readBuf);
    try std.zip.extract(destDir, &reader, .{});
}

test "CRX3 offset lands right after the protobuf header" {
    var crx = std.ArrayList(u8).empty;
    defer crx.deinit(std.testing.allocator);
    try crx.appendSlice(std.testing.allocator, "Cr24");
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 3)));
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 10)));
    try crx.appendNTimes(std.testing.allocator, 0xAA, 10); // fake protobuf header
    try crx.appendSlice(std.testing.allocator, "PK\x03\x04rest-of-zip");

    const offset = try zipOffset(crx.items);
    try std.testing.expectEqual(@as(usize, 22), offset);
    try std.testing.expectEqualStrings("PK\x03\x04rest-of-zip", crx.items[offset..]);
}

test "CRX2 offset accounts for both the pubkey and the signature" {
    var crx = std.ArrayList(u8).empty;
    defer crx.deinit(std.testing.allocator);
    try crx.appendSlice(std.testing.allocator, "Cr24");
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 2)));
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 5))); // pubkey_len
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 3))); // sig_len
    try crx.appendNTimes(std.testing.allocator, 0xBB, 5);
    try crx.appendNTimes(std.testing.allocator, 0xCC, 3);
    try crx.appendSlice(std.testing.allocator, "PK\x03\x04zip");

    const offset = try zipOffset(crx.items);
    try std.testing.expectEqual(@as(usize, 24), offset);
}

test "rejects a file that isn't a CRX at all" {
    try std.testing.expectError(error.NotACrxFile, zipOffset("not a crx file"));
}

test "rejects an unknown CRX version rather than guessing a layout" {
    var crx = std.ArrayList(u8).empty;
    defer crx.deinit(std.testing.allocator);
    try crx.appendSlice(std.testing.allocator, "Cr24");
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 99)));
    try crx.appendNTimes(std.testing.allocator, 0, 8);
    try std.testing.expectError(error.UnsupportedCrxVersion, zipOffset(crx.items));
}

test "a header that claims more bytes than the file has is truncated, not out-of-bounds" {
    var crx = std.ArrayList(u8).empty;
    defer crx.deinit(std.testing.allocator);
    try crx.appendSlice(std.testing.allocator, "Cr24");
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 3)));
    try crx.appendSlice(std.testing.allocator, &std.mem.toBytes(@as(u32, 1_000_000)));
    try std.testing.expectError(error.TruncatedHeader, zipOffset(crx.items));
}
