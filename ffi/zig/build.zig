// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{ .name = "laminar_ffi", .root_source_file = b.path("src/laminar_ffi.zig"), .target = target, .optimize = optimize });
    b.installArtifact(lib);
    const tests = b.addTest(.{ .root_source_file = b.path("src/laminar_ffi.zig"), .target = target, .optimize = optimize });
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
