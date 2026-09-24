//! Vector pointers preserve ZMM memory operations under Intel prefer_256_bit.
const builtin = @import("builtin");
const tuning = @import("tuning.zig");
pub const width = tuning.vec;
pub const V: type = @Vector(width, u8);
pub const mask_available = builtin.zig_backend == .stage2_llvm and tuning.avx512;
const M64: type = @Vector(64, bool);
extern fn @"llvm.masked.store.v64i8.p0"(
    value: @Vector(64, u8),
    ptr: *anyopaque,
    alignment: u32,
    mask: M64,
) void;

pub inline fn load(comptime T: type, src: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(src)).*;
}
pub inline fn store(comptime T: type, dst: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(dst)).* = value;
}
pub inline fn storeAligned(dst: [*]u8, value: V) void {
    @as(*align(width) V, @ptrCast(@alignCast(dst))).* = value;
}
pub inline fn maskedSet(dst: [*]u8, value: u8, n: usize) void {
    if (comptime !mask_available) @compileError("maskedSet requires LLVM and AVX-512BW");
    const bits = (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
    @"llvm.masked.store.v64i8.p0"(@splat(value), dst, 1, @bitCast(bits));
}
pub inline fn streamStore(dst: [*]u8, value: V) void {
    if (comptime builtin.zig_backend != .stage2_llvm) {
        storeAligned(dst, value);
        return;
    }
    asm volatile ("vmovntdq %[value], (%[dst])"
        :
        : [value] "v" (value),
          [dst] "r" (dst),
        : .{ .memory = true });
}
pub inline fn fence() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}
pub inline fn repMove(dst: [*]u8, src: [*]const u8, n: usize) void {
    var d = dst;
    var s = src;
    var count = n;
    asm volatile ("rep movsb"
        : [d] "={rdi}" (d),
          [s] "={rsi}" (s),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [s_in] "{rsi}" (s),
          [count_in] "{rcx}" (count),
        : .{ .memory = true });
}
pub inline fn repSet(dst: [*]u8, value: u8, n: usize) void {
    var d = dst;
    var count = n;
    asm volatile ("rep stosb"
        : [d] "={rdi}" (d),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [count_in] "{rcx}" (count),
          [value] "{al}" (value),
        : .{ .memory = true });
}
