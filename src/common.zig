const std = @import("std");
const assert = std.debug.assert;
const simd = std.simd;
const math = std.math;
const builtin = @import("builtin");

extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

/// Native vector width in bytes, selected at comptime. Capped at 32B
/// because AVX-512 zmm usage causes frequency throttling on Intel cores.
pub const chunk_bytes = @min(simd.suggestVectorLength(u8) orelse 16, 32);

/// SIMD vector type — q-register on NEON, ymm on AVX2.
pub const Chunk = @Vector(chunk_bytes, u8); // ziglint-ignore: Z006

/// Vectors per inner loop iteration.
pub const vectors_per_stride = 4;

/// Bytes per inner loop iteration.
pub const stride = chunk_bytes * vectors_per_stride;

pub const can_use_glibc_memops = builtin.link_libc and builtin.os.tag == .linux and builtin.abi == .gnu;

comptime {
    assert(math.isPowerOfTwo(chunk_bytes));
    assert(math.isPowerOfTwo(stride));
}

pub inline fn byteLen(comptime T: type, count: usize) usize {
    if (comptime @sizeOf(T) == 0) return 0;
    if (count == 0) return 0;

    assert(count <= math.maxInt(usize) / @sizeOf(T));
    return count * @sizeOf(T);
}

pub inline fn callLibcMemcpy(dest: [*]u8, src: [*]const u8, len: usize) void {
    _ = memcpy(@ptrCast(dest), @ptrCast(src), len);
}

pub inline fn callLibcMemmove(dest: [*]u8, src: [*]const u8, len: usize) void {
    _ = memmove(@ptrCast(dest), @ptrCast(src), len);
}

/// Handles 0..stride-1 bytes using overlapping loads at progressively
/// larger widths. All loads complete before any stores, making this
/// safe for overlapping regions in either direction.
pub fn copySmall(dest: [*]u8, src: [*]const u8, len: usize) void {
    if (len >= chunk_bytes * 2) {
        // 2*chunk..stride-1: four overlapping vectors.
        const h0 = loadV(src);
        const h1 = loadV(src + chunk_bytes);
        const t0 = loadV(src + len - chunk_bytes * 2);
        const t1 = loadV(src + len - chunk_bytes);
        storeV(dest, h0);
        storeV(dest + chunk_bytes, h1);
        storeV(dest + len - chunk_bytes * 2, t0);
        storeV(dest + len - chunk_bytes, t1);
    } else if (len >= chunk_bytes) {
        // chunk..2*chunk-1: two overlapping vectors.
        const head = loadV(src);
        const tail = loadV(src + len - chunk_bytes);
        storeV(dest, head);
        storeV(dest + len - chunk_bytes, tail);
    } else if (chunk_bytes > 16 and len >= 16) {
        // 16..chunk-1: two overlapping 128-bit loads (AVX2 only;
        // on NEON chunk_bytes==16 so the vector branch above handles this).
        const head = loadU(u128, src);
        const tail = loadU(u128, src + len - 16);
        storeU(u128, dest, head);
        storeU(u128, dest + len - 16, tail);
    } else if (len >= 8) {
        // 8..15: two overlapping 64-bit loads.
        const head = loadU(u64, src);
        const tail = loadU(u64, src + len - 8);
        storeU(u64, dest, head);
        storeU(u64, dest + len - 8, tail);
    } else if (len >= 4) {
        // 4..7: two overlapping 4-byte loads.
        const head = loadU(u32, src);
        const tail = loadU(u32, src + len - 4);
        storeU(u32, dest, head);
        storeU(u32, dest + len - 4, tail);
    } else if (len > 0) {
        // 1..3: three overlapping byte copies.
        const a = src[0];
        const b = src[len >> 1];
        const c = src[len - 1];
        dest[0] = a;
        dest[len >> 1] = b;
        dest[len - 1] = c;
    }
}

/// Load `count` contiguous vectors starting at `ptr + off`.
pub inline fn loadVN(comptime count: comptime_int, ptr: [*]const u8, off: usize) [count]Chunk {
    var vecs: [count]Chunk = undefined;
    inline for (0..count) |i| {
        vecs[i] = loadV(ptr + off + chunk_bytes * i);
    }
    return vecs;
}

/// Store `count` contiguous vectors starting at `ptr + off`.
pub inline fn storeVN(comptime count: comptime_int, ptr: [*]u8, off: usize, vecs: [count]Chunk) void {
    inline for (0..count) |i| {
        storeV(ptr + off + chunk_bytes * i, vecs[i]);
    }
}

pub inline fn loadV(ptr: [*]const u8) Chunk {
    const arr: *align(1) const [chunk_bytes]u8 = @ptrCast(ptr);
    return arr.*;
}

pub inline fn storeV(ptr: [*]u8, v: Chunk) void {
    const arr: *align(1) [chunk_bytes]u8 = @ptrCast(ptr);
    arr.* = v;
}

pub inline fn loadU(comptime T: type, ptr: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(ptr)).*;
}

pub inline fn storeU(comptime T: type, ptr: [*]u8, val: T) void {
    @as(*align(1) T, @ptrCast(ptr)).* = val;
}
