//! The root of one kernel object of the x86_64 runtime dispatch
//! (docs/runtime-dispatch.md). build.zig compiles this file once per
//! level, with -Dcpu set to the level name. The object contains the same
//! kernels as a comptime build for that CPU, under hidden symbol names
//! that contain the level name.
const std = @import("std");
const builtin = @import("builtin");
const move = @import("move.zig");
const set = @import("set.zig");
const tuning = @import("tuning.zig");

const prefix = "fastmem_x86_" ++ builtin.cpu.model.name ++ "_";
const kernel_name = std.fmt.comptimePrint("{s}", .{tuning.name});

comptime {
    if (!tuning.available) @compileError("a dispatch level object requires AVX2");
    @export(&move.kernel, .{ .name = prefix ++ "memmove", .visibility = .hidden });
    @export(&set.kernel, .{ .name = prefix ++ "memset", .visibility = .hidden });
    @export(&name, .{ .name = prefix ++ "name", .visibility = .hidden });
}

// A function, not a data symbol: the harness disassembles every
// fastmem_* symbol of the benchmark binary.
fn name() callconv(.c) [*:0]const u8 {
    return kernel_name.ptr;
}
