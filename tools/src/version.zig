//! Chrome extension version comparison.
//!
//! The task that asked for this called it "semantic version matching," but
//! Chrome extension versions are not semver: `manifest.json`'s `version`
//! field is 1-4 dot-separated non-negative integers with no prerelease or
//! build-metadata suffix (see the real versions in ../../extensions.json —
//! "2.0.0.0017", "6.4.2026.0501"). Comparing them as semver would either
//! reject them outright or mis-order them (semver caps at 3 components and
//! treats a leading zero specially; Chrome does neither). This compares
//! them the way Chrome itself does: component-wise as integers, missing
//! trailing components treated as zero.

const std = @import("std");

pub const ParseError = error{TooManyComponents};

/// Parses up to 4 dot-separated integer components. Missing trailing
/// components are zero-filled at compare time, not here, so "1.2" and
/// "1.2.0.0" parse to different lengths but still compare equal.
pub fn parse(text: []const u8) ParseError![4]u32 {
    var components = [4]u32{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.TooManyComponents;
        // A component that fails to parse (garbage, negative, too large) is
        // treated as 0 rather than propagating an error: a malformed version
        // string from a compromised or misbehaving update server should sort
        // as "old", not crash the whole update check.
        components[i] = std.fmt.parseInt(u32, part, 10) catch 0;
    }
    return components;
}

pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    const pa = parse(a) catch [4]u32{ 0, 0, 0, 0 };
    const pb = parse(b) catch [4]u32{ 0, 0, 0, 0 };
    for (pa, pb) |ca, cb| {
        const order = std.math.order(ca, cb);
        if (order != .eq) return order;
    }
    return .eq;
}

pub fn isNewer(candidate: []const u8, than: []const u8) bool {
    return compare(candidate, than) == .gt;
}

test "equal versions with different component counts compare equal" {
    try std.testing.expectEqual(std.math.Order.eq, compare("1.2", "1.2.0.0"));
    try std.testing.expectEqual(std.math.Order.eq, compare("0", ""));
}

test "compares component-wise, not lexicographically" {
    // Lexicographic comparison would put "1.9" after "1.10" — wrong. This is
    // exactly the class of bug real semver libraries avoid too, just via a
    // different grammar than the one Chrome's version field actually uses.
    try std.testing.expect(isNewer("1.10", "1.9"));
    try std.testing.expect(isNewer("2.0.0.0017", "2.0.0.16"));
}

test "real versions from extensions.json compare correctly" {
    try std.testing.expect(isNewer("6.4.2026.0502", "6.4.2026.0501"));
    try std.testing.expect(!isNewer("4.9.1", "4.9.1"));
    try std.testing.expect(isNewer("4.9.2", "4.9.1"));
}

test "garbage input degrades to zero instead of erroring" {
    try std.testing.expectEqual(std.math.Order.eq, compare("a.b.c", ""));
    try std.testing.expect(isNewer("1.0", "a.b.c"));
}

test "more than 4 components is rejected, not silently truncated" {
    try std.testing.expectError(error.TooManyComponents, parse("1.2.3.4.5"));
}
