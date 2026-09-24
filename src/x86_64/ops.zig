//! vector pointers preserve ZMM memory operations under Intel prefer_256_bit.
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const builtin = @import("builtin");
const tuning = @import("tuning.zig");
pub const width = tuning.vec;
pub const vector: type = @Vector(width, u8);
pub const mask_available = builtin.zig_backend == .stage2_llvm and tuning.avx512;
const mask: type = @Vector(64, bool);
extern fn @"llvm.masked.store.v64i8.p0"(
    value: @Vector(64, u8),
    ptr: *anyopaque,
    alignment: u32,
    mask: mask,
) void;

pub inline fn load(comptime T: type, src: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(src)).*;
}
pub inline fn store(comptime T: type, dst: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(dst)).* = value;
}
pub inline fn storeAligned(dst: [*]u8, value: vector) void {
    @as(*align(width) vector, @ptrCast(@alignCast(dst))).* = value;
}
pub inline fn maskedSet(dst: [*]u8, value: u8, n: usize) void {
    if (comptime !mask_available) @compileError("maskedSet requires LLVM and AVX-512BW");
    const bits = (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
    @"llvm.masked.store.v64i8.p0"(@splat(value), dst, 1, @bitCast(bits));
}
pub inline fn streamStore(dst: [*]u8, value: vector) void {
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

// High EVEX registers do not dirty the low register bank that needs vzeroupper.
// The fragments implement the same independent head/tail classes as move.small.
pub const high_available = tuning.high_regs and builtin.zig_backend == .stage2_llvm;

fn highCopyText(comptime bytes: u32, comptime count: u32) []const u8 {
    comptime var text: []const u8 = "";
    const reg = if (bytes == 64) "zmm" else "ymm";
    inline for (.{ "load", "store" }) |phase| {
        inline for (0..count) |i| {
            const offset: i32 = if (i < count / 2)
                @intCast(i * bytes)
            else
                -@as(i32, @intCast((count - i) * bytes));
            const suffix = if (i < count / 2) "" else ",%[n]";
            text = text ++ if (comptime mem.eql(u8, phase, "load"))
                fmt.comptimePrint("vmovdqu64 {d}(%[src]{s}), %%{s}{d}\n", .{
                    offset,
                    suffix,
                    reg,
                    16 + i,
                })
            else
                fmt.comptimePrint("vmovdqu64 %%{s}{d}, {d}(%[dst]{s})\n", .{
                    reg,
                    16 + i,
                    offset,
                    suffix,
                });
        }
    }
    return text;
}

pub inline fn highMove(
    comptime bytes: u32,
    comptime count: u32,
    dst: [*]u8,
    src: [*]const u8,
    n: usize,
) void {
    if (comptime !high_available) @compileError("highMove requires LLVM and AVX-512BW");
    asm volatile (highCopyText(bytes, count)
        :
        : [dst] "r" (dst),
          [src] "r" (src),
          [n] "r" (n),
        : .{
          .zmm16 = true,
          .zmm17 = true,
          .zmm18 = true,
          .zmm19 = true,
          .zmm20 = true,
          .zmm21 = true,
          .zmm22 = true,
          .zmm23 = true,
          .memory = true,
        });
}

fn highSetText(comptime bytes: u32, comptime count: u32) []const u8 {
    const reg = if (bytes == 64) "zmm" else "ymm";
    comptime var text: []const u8 = "vpbroadcastb %[value], %%" ++ reg ++ "16\n";
    inline for (0..count) |i| {
        const offset: i32 = if (i < count / 2)
            @intCast(i * bytes)
        else
            -@as(i32, @intCast((count - i) * bytes));
        const suffix = if (i < count / 2) "" else ",%[n]";
        text = text ++ fmt.comptimePrint("vmovdqu64 %%{s}16, {d}(%[dst]{s})\n", .{
            reg,
            offset,
            suffix,
        });
    }
    return text;
}

pub inline fn highSet(
    comptime bytes: u32,
    comptime count: u32,
    dst: [*]u8,
    value: c_int,
    n: usize,
) void {
    if (comptime !high_available) @compileError("highSet requires LLVM and AVX-512BW");
    asm volatile (highSetText(bytes, count)
        :
        : [dst] "r" (dst),
          [value] "r" (value),
          [n] "r" (n),
        : .{ .zmm16 = true, .memory = true });
}
