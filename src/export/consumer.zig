const std = @import("std");
const fastmem = @import("fastmem");
const options = @import("export_options");

comptime {
    if (options.enabled) fastmem.exportSymbols();
    if (options.division) @export(&divide, .{ .name = "p6_divide" });
}

// The checker reads these relocations from the final ELF image.
export const p6_memcpy = fastmem.abi.memcpy;
export const p6_memmove = fastmem.abi.memmove;
export const p6_memset = fastmem.abi.memset;

export fn p6_copy(d: [*]u8, s: [*]const u8, n: usize) void {
    @memcpy(d[0..n], s[0..n]);
}
export fn p6_move(d: [*]u8, s: [*]const u8, n: usize) void {
    @memmove(d[0..n], s[0..n]);
}
export fn p6_set(d: [*]u8, v: u8, n: usize) void {
    @memset(d[0..n], v);
}
fn divide(a: u128, b: u128) callconv(.c) u128 {
    return a / b;
}
extern fn p6_c_copy(d: [*]u8, s: [*]const u8, n: usize) void;
extern fn p6_c_move(d: [*]u8, s: [*]const u8, n: usize) void;
extern fn p6_c_set(d: [*]u8, v: c_int, n: usize) void;

pub fn main() void {
    var src: [8192]u8 = undefined;
    var dst: [8193]u8 = undefined;
    for (&src, 0..) |*v, i| v.* = @truncate(i *% 37 +% 11);
    for (0..8193) |n| {
        p6_copy(&dst, &src, n);
        for (0..n) |i| require(dst[i] == src[i]);
        p6_move(dst[1..].ptr, &dst, n);
        for (0..n) |i| require(dst[i + 1] == src[i]);
        p6_move(&dst, dst[1..].ptr, n);
        for (0..n) |i| require(dst[i] == src[i]);
        p6_set(&dst, 0xa7, n);
        for (0..n) |i| require(dst[i] == 0xa7);
        p6_c_copy(&dst, &src, n);
        for (0..n) |i| require(dst[i] == src[i]);
        p6_c_move(dst[1..].ptr, &dst, n);
        for (0..n) |i| require(dst[i + 1] == src[i]);
        p6_c_set(&dst, 0x1b3, n);
        for (0..n) |i| require(dst[i] == 0xb3);
    }
    if (options.division) {
        var a: u128 = (@as(u128, 1) << 100) + 17;
        var b: u128 = 3;
        const ap: *volatile u128 = &a;
        const bp: *volatile u128 = &b;
        require(divide(ap.*, bp.*) == ((@as(u128, 1) << 100) + 17) / 3);
    }
}
fn require(ok: bool) void {
    if (!ok) std.os.linux.exit(1);
}
