const std = @import("std");

// This fixture is deliberately recursive. No test executes the binary.
comptime {
    @export(&badCopy, .{ .name = "memcpy", .visibility = .hidden });
    @export(&badCopy, .{ .name = "memmove", .visibility = .hidden });
    @export(&dummySet, .{ .name = "memset", .visibility = .hidden });
}
export const p6_memcpy = &badCopy;
export const p6_memmove = &badCopy;
export const p6_memset = &dummySet;

fn badCopy(d: [*]u8, s: [*]const u8, n: usize) callconv(.c) [*]u8 {
    @disableIntrinsics();
    _ = @call(.never_inline, std.mem.replace, .{ u8, s[0..n], "x", "y", d[0..n] });
    return d;
}

fn dummySet(d: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    _ = .{ c, n };
    return d;
}

pub fn main() void {}
