//! A consumer of two fastmem package copies (src/export/two_packages.py).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const a = b.dependency("fastmem_a", .{ .target = target });
    const other = b.dependency("fastmem_b", .{ .target = target });
    const exe = b.addExecutable(.{
        .name = "two-packages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fastmem_a", .module = a.module("fastmem") },
                .{ .name = "fastmem_b", .module = other.module("fastmem") },
            },
        }),
    });
    b.installArtifact(exe);
}
