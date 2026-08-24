const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yuku = b.dependency("yuku", .{ .target = target, .optimize = optimize });

    const lib_mod = b.addModule("filter_sources_tools", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("parser", yuku.module("parser"));

    const exe = b.addExecutable(.{ .name = "check", .root_module = lib_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |cli_args| run.addArgs(cli_args);
    b.step("run", "Run the checker").dependOn(&run.step);

    const test_mods = [_][]const u8{
        "src/version.zig",
        "src/crx.zig",
        "src/signatures.zig",
        "src/patchDetect.zig",
    };
    const test_step = b.step("test", "Run all unit tests");
    for (test_mods) |path| {
        const mod = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
        mod.addImport("parser", yuku.module("parser"));
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
    const omaha_mod = b.createModule(.{ .root_source_file = b.path("src/omaha.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = omaha_mod })).step);
    const deob_mod = b.createModule(.{ .root_source_file = b.path("src/deobfuscator.zig"), .target = target, .optimize = optimize });
    deob_mod.addImport("parser", yuku.module("parser"));
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = deob_mod })).step);
}
