const std = @import("std");

pub const panic = std.debug.FullPanic(struct {
    fn panic(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.panic);
// ziglint-ignore: Z001 - The binary checker requires this C-ABI symbol name.
export fn p6_copy(d: [*]u8, s: [*]const u8, n: usize) void {
    @memcpy(d[0..n], s[0..n]);
}
// ziglint-ignore: Z001 - The binary checker requires this C-ABI symbol name.
export fn p6_move(d: [*]u8, s: [*]const u8, n: usize) void {
    @memmove(d[0..n], s[0..n]);
}
// ziglint-ignore: Z001 - The binary checker requires this C-ABI symbol name.
export fn p6_set(d: [*]u8, v: u8, n: usize) void {
    @memset(d[0..n], v);
}
