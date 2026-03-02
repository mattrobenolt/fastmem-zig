//! Fast memory operations using native SIMD vectors.
//!
//! Vector width is selected at comptime via std.simd.suggestVectorLength,
//! capped at 32B (256-bit). NEON = 16B, AVX2 = 32B. The inner loop
//! unroll factor is controlled by `vectors_per_stride` (default 4,
//! giving 64B/iter on NEON, 128B/iter on AVX2). On aarch64, LLVM
//! merges adjacent vector loads/stores into ldp/stp pairs automatically.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const simd = std.simd;
const builtin = @import("builtin");

/// Per-CPU tuning knobs. All fields have conservative defaults; override
/// per cpu.model
pub const Flags = struct {
    /// Pointer-bumping loop (tight codegen) vs single-offset loop.
    tight_loop: bool = true,
    /// Straight-line medium tiers (stride, stride*2) before entering the loop.
    medium_straight_line: bool = false,
    /// Min bytes before copy alignment peel, as stride multiples.
    copy_align_peel_min_strides: comptime_int = 2,
    /// Forward-move peel floor in bytes (actual min = max(stride*2, this)).
    move_fwd_peel_min_bytes: comptime_int = 2048,
    /// Backward-move peel in stride multiples.
    move_bwd_peel_min_strides: comptime_int = 2,
    /// Fall back to @memcpy for large aligned copies (rep movsb on ERMS/FSRM x86).
    large_copy_use_builtin: bool = false,
    /// Threshold for large_copy_use_builtin (bytes).
    large_copy_builtin_threshold: comptime_int = 4096,
};

pub const flags: Flags = switch (builtin.cpu.arch) {
    .aarch64 => if (builtin.cpu.model == &std.Target.aarch64.cpu.generic)
        .{ .tight_loop = false, .medium_straight_line = true, .copy_align_peel_min_strides = 8 }
    else if (builtin.cpu.model == &std.Target.aarch64.cpu.apple_m1)
        .{ .large_copy_use_builtin = true, .large_copy_builtin_threshold = 1024 }
    else
        .{},
    .x86_64 => if (builtin.cpu.model == &std.Target.x86.cpu.x86_64)
        .{ .tight_loop = false, .medium_straight_line = true, .copy_align_peel_min_strides = 8 }
    else if (builtin.cpu.model == &std.Target.x86.cpu.sapphirerapids)
        .{ .large_copy_use_builtin = true, .large_copy_builtin_threshold = 2048 }
    else
        .{},
    else => .{},
};

/// Native vector width in bytes, selected at comptime. Capped at 32B
/// because AVX-512 zmm usage causes frequency throttling on Intel cores.
const chunk_bytes = @min(simd.suggestVectorLength(u8) orelse 16, 32);

/// SIMD vector type — q-register on NEON, ymm on AVX2.
const Chunk = @Vector(chunk_bytes, u8); // ziglint-ignore: Z006

/// Vectors per inner loop iteration.
const vectors_per_stride = 4;

/// Bytes per inner loop iteration.
const stride = chunk_bytes * vectors_per_stride;

const copy_align_peel_min = flags.copy_align_peel_min_strides * stride;
const move_forward_align_peel_min: usize = @max(stride * 2, flags.move_fwd_peel_min_bytes);
const move_backward_align_peel_min = flags.move_bwd_peel_min_strides * stride;

comptime {
    assert(std.math.isPowerOfTwo(chunk_bytes));
    assert(std.math.isPowerOfTwo(stride));
    assert(copy_align_peel_min >= stride);
    assert(move_forward_align_peel_min >= stride);
    assert(move_backward_align_peel_min >= stride);
}

inline fn byteLen(comptime T: type, count: usize) usize {
    if (comptime @sizeOf(T) == 0) return 0;
    if (count == 0) return 0;

    assert(count <= std.math.maxInt(usize) / @sizeOf(T));
    return count * @sizeOf(T);
}

/// Non-overlapping copy. Prefer over @memcpy for runtime-sized copies
/// that may exceed ~32 bytes.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);

    const byte_len = byteLen(T, source.len);
    if (byte_len == 0) return;

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);
    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    assert(s_addr <= std.math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;
    assert(d_addr <= s_addr or d_addr >= s_end);

    copyFwd(copy_align_peel_min, true, d, s, byte_len);
}

/// Overlapping-safe move. Prefer over @memmove for runtime-sized moves.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);

    const byte_len = byteLen(T, source.len);
    if (byte_len == 0) return;

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);
    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    assert(s_addr <= std.math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;

    // Forward is safe when dest <= src or regions don't overlap.
    if (d_addr <= s_addr) return copyFwd(move_forward_align_peel_min, false, d, s, byte_len);
    if (d_addr >= s_end) {
        return copyFwd(move_forward_align_peel_min, false, d, s, byte_len);
    }

    // Overlapping with dest > src.
    // Small path loads all data before any stores — inherently safe.
    if (byte_len < stride) return copySmall(d, s, byte_len);

    var remaining = byte_len;

    // Peel an unaligned tail only when enough work remains to amortize it.
    if (remaining >= move_backward_align_peel_min) {
        const mask = @as(usize, chunk_bytes - 1);
        const end_misalignment = (@intFromPtr(d) + remaining) & mask;
        if (end_misalignment > 0) {
            copySmall(d + remaining - end_misalignment, s + remaining - end_misalignment, end_misalignment);
            remaining -= end_misalignment;
        }
    }

    if (remaining < stride) return copySmall(d, s, remaining);
    copyLargeBackward(d, s, remaining);
}

inline fn copyFwd(
    comptime align_peel_min: comptime_int,
    comptime allow_builtin_fallback: bool,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    var d = dest;
    var s = src;
    var remaining = len;

    if (remaining < stride) return copySmall(d, s, remaining);

    // On targets where LLVM generates a bloated loop body, bypass the
    // loop for medium sizes with straight-line loads then stores.
    // All loads complete before any stores — safe for overlapping regions.
    if (flags.medium_straight_line) {
        if (remaining <= stride) {
            storeVN(vectors_per_stride, d, 0, loadVN(vectors_per_stride, s, 0));
            return;
        }
        if (remaining <= stride * 2) {
            const head = loadVN(vectors_per_stride, s, 0);
            const tail = loadVN(vectors_per_stride, s, remaining - stride);
            storeVN(vectors_per_stride, d, 0, head);
            storeVN(vectors_per_stride, d, remaining - stride, tail);
            return;
        }
    }

    // Align destination for vector stores only when enough work remains.
    if (remaining >= align_peel_min) {
        const mask = @as(usize, chunk_bytes - 1);
        const dest_misalignment = @intFromPtr(d) & mask;
        if (dest_misalignment > 0) {
            const prefix = @as(usize, chunk_bytes) - dest_misalignment;
            copySmall(d, s, prefix);
            d += prefix;
            s += prefix;
            remaining -= prefix;
        }
    }

    if (remaining < stride) return copySmall(d, s, remaining);
    copyLargeForward(allow_builtin_fallback, d, s, remaining);
}

/// Handles 0..stride-1 bytes using overlapping loads at progressively
/// larger widths. All loads complete before any stores, making this
/// safe for overlapping regions in either direction.
fn copySmall(dest: [*]u8, src: [*]const u8, len: usize) void {
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
inline fn loadVN(comptime count: comptime_int, ptr: [*]const u8, off: usize) [count]Chunk {
    var vecs: [count]Chunk = undefined;
    inline for (0..count) |i| {
        vecs[i] = loadV(ptr + off + chunk_bytes * i);
    }
    return vecs;
}

/// Store `count` contiguous vectors starting at `ptr + off`.
inline fn storeVN(comptime count: comptime_int, ptr: [*]u8, off: usize, vecs: [count]Chunk) void {
    inline for (0..count) |i| {
        storeV(ptr + off + chunk_bytes * i, vecs[i]);
    }
}

/// Forward loop for >= stride bytes.
inline fn copyLargeForward(
    comptime allow_builtin_fallback: bool,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    assert(len >= stride);

    // Delegate to the platform's optimized implementation for large
    // non-overlapping copies. Only used from copy(), not from move().
    if (allow_builtin_fallback and flags.large_copy_use_builtin and len >= flags.large_copy_builtin_threshold) {
        @memcpy(dest[0..len], src[0..len]);
        return;
    }

    if (flags.tight_loop) {
        // Pointer bumping: known models produce tight codegen.
        var d = dest;
        var s = src;
        var remaining = len;
        while (remaining >= stride) {
            storeVN(vectors_per_stride, d, 0, loadVN(vectors_per_stride, s, 0));
            d += stride;
            s += stride;
            remaining -= stride;
        }
        if (remaining > 0) copySmall(d, s, remaining);
    } else {
        // Single offset: generic targets produce bloated codegen with
        // multiple induction variables; a single offset keeps the loop
        // body smaller.
        var off: usize = 0;
        while (off + stride <= len) : (off += stride) {
            storeVN(vectors_per_stride, dest + off, 0, loadVN(vectors_per_stride, src + off, 0));
        }
        const remaining = len - off;
        if (remaining > 0) copySmall(dest + off, src + off, remaining);
    }
}

/// Backward loop for >= stride bytes with overlapping dest > src.
/// Finishes with copySmall for the remaining prefix.
inline fn copyLargeBackward(
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    assert(len >= stride);

    if (flags.tight_loop) {
        var d = dest + len;
        var s = src + len;
        var remaining = len;
        while (remaining >= stride) {
            d -= stride;
            s -= stride;
            storeVN(vectors_per_stride, d, 0, loadVN(vectors_per_stride, s, 0));
            remaining -= stride;
        }
        if (remaining > 0) copySmall(dest, src, remaining);
    } else {
        var off = len;
        while (off >= stride) {
            off -= stride;
            storeVN(vectors_per_stride, dest + off, 0, loadVN(vectors_per_stride, src + off, 0));
        }
        if (off > 0) copySmall(dest, src, off);
    }
}

// -- Unaligned load/store helpers --

inline fn loadV(ptr: [*]const u8) Chunk {
    const arr: *align(1) const [chunk_bytes]u8 = @ptrCast(ptr);
    return arr.*;
}

inline fn storeV(ptr: [*]u8, v: Chunk) void {
    const arr: *align(1) [chunk_bytes]u8 = @ptrCast(ptr);
    arr.* = v;
}

inline fn loadU(comptime T: type, ptr: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(ptr)).*;
}

inline fn storeU(comptime T: type, ptr: [*]u8, val: T) void {
    @as(*align(1) T, @ptrCast(ptr)).* = val;
}

test "copy: all size classes" {
    const sizes = [_]usize{
        0,  1,  2,   3,   4,   5,   7,   8,
        12, 15, 16,  24,  31,  32,  48,  63,
        64, 96, 127, 128, 200, 256, 512, 1024,
    };
    for (sizes) |len| {
        var src: [1024]u8 = undefined;
        for (&src, 0..) |*b, i| b.* = @truncate(i);

        var dest: [1024]u8 = .{0} ** 1024;
        copy(u8, dest[0..len], src[0..len]);

        try testing.expectEqualSlices(u8, src[0..len], dest[0..len]);
    }
}

test "copy: typed elements" {
    const sizes = [_]usize{ 0, 1, 2, 3, 5, 8, 13, 21, 34, 55 };
    for (sizes) |len| {
        var src: [64]u32 = undefined;
        for (&src, 0..) |*value, i| value.* = @intCast(i * 17 + 3);

        var dest: [64]u32 = .{0} ** 64;
        copy(u32, dest[0..len], src[0..len]);

        try testing.expectEqualSlices(u32, src[0..len], dest[0..len]);
    }
}

test "copy: alignment and length matrix" {
    const max_len = 320;
    const max_offset = chunk_bytes;
    var source_buf: [max_len + chunk_bytes]u8 align(chunk_bytes) = undefined;
    for (&source_buf, 0..) |*b, i| b.* = @truncate(i * 13 + 5);

    var dest_buf: [max_len + chunk_bytes]u8 align(chunk_bytes) = undefined;
    for (0..max_len + 1) |len| {
        for (0..max_offset) |source_offset| {
            const source = source_buf[source_offset..][0..len];

            for (0..max_offset) |dest_offset| {
                @memset(&dest_buf, 0xA5);
                const dest = dest_buf[dest_offset..][0..len];

                copy(u8, dest, source);
                try testing.expectEqualSlices(u8, source, dest);
            }
        }
    }
}

test "move: forward overlapping (dest < src)" {
    // Simulate buffer compaction: shift data left by various gaps.
    const gaps = [_]usize{ 1, 2, 7, 15, 16, 31, 32, 63, 64, 100 };
    for (gaps) |gap| {
        var buf: [512]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);

        const len: usize = 400;
        var expected: [512]u8 = undefined;
        @memcpy(expected[0..len], buf[gap..][0..len]);

        move(u8, buf[0..len], buf[gap..][0..len]);
        try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
    }
}

test "move: typed elements in both overlap directions" {
    const gaps = [_]usize{ 1, 2, 5, 9, 17 };
    const len: usize = 120;

    for (gaps) |gap| {
        var forward_buf: [256]u16 = undefined;
        for (&forward_buf, 0..) |*value, i| value.* = @intCast(i * 31 + gap);
        var forward_expected = forward_buf;

        @memmove(forward_expected[0..len], forward_expected[gap..][0..len]);
        move(u16, forward_buf[0..len], forward_buf[gap..][0..len]);
        try testing.expectEqualSlices(u16, forward_expected[0..len], forward_buf[0..len]);

        var backward_buf: [256]u16 = undefined;
        for (&backward_buf, 0..) |*value, i| value.* = @intCast(i * 31 + gap);
        var backward_expected = backward_buf;

        @memmove(backward_expected[gap..][0..len], backward_expected[0..len]);
        move(u16, backward_buf[gap..][0..len], backward_buf[0..len]);
        try testing.expectEqualSlices(
            u16,
            backward_expected[gap..][0..len],
            backward_buf[gap..][0..len],
        );
    }
}

test "move: overlap matrix around stride" {
    const max_len = stride + chunk_bytes;
    const max_gap = chunk_bytes * 2;
    const buf_len = max_len + max_gap;

    var base: [buf_len]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @truncate(i * 29 + 11);

    for (0..max_len + 1) |len| {
        for (0..max_gap + 1) |gap| {
            if (len + gap > buf_len) continue;

            var forward_buf = base;
            var forward_expected = base;
            @memmove(forward_expected[0..len], forward_expected[gap..][0..len]);
            move(u8, forward_buf[0..len], forward_buf[gap..][0..len]);
            try testing.expectEqualSlices(u8, forward_expected[0..len], forward_buf[0..len]);

            var backward_buf = base;
            var backward_expected = base;
            @memmove(backward_expected[gap..][0..len], backward_expected[0..len]);
            move(u8, backward_buf[gap..][0..len], backward_buf[0..len]);
            try testing.expectEqualSlices(
                u8,
                backward_expected[gap..][0..len],
                backward_buf[gap..][0..len],
            );
        }
    }
}

test "move: backward overlapping (dest > src)" {
    const gaps = [_]usize{ 1, 2, 7, 15, 16, 31, 32, 63, 64, 100 };
    for (gaps) |gap| {
        var buf: [512]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);

        const len: usize = 300;
        var expected: [512]u8 = undefined;
        @memcpy(expected[gap..][0..len], buf[0..len]);

        move(u8, buf[gap..][0..len], buf[0..len]);
        try testing.expectEqualSlices(
            u8,
            expected[gap..][0..len],
            buf[gap..][0..len],
        );
    }
}

test "fuzz copy" {
    try testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 2) return;
            const len: usize = @min(
                input[0],
                @as(u8, @intCast(@min(input.len - 1, 255))),
            );
            const src = input[1..][0..len];

            var dest: [256]u8 = .{0} ** 256;
            copy(u8, dest[0..len], src);
            try testing.expectEqualSlices(u8, src, dest[0..len]);
        }
    }.run, .{
        .corpus = &.{
            "",
            &.{0},
            &.{ 64, 'a', 'b', 'c' },
        },
    });
}

test "fuzz move forward" {
    try testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 3) return;
            const len: usize = @min(input[0], 200);
            const gap: usize = @min(input[1], 100);
            if (len == 0) return;

            var buf: [512]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i ^ input[2]);

            var expected = buf;
            @memmove(expected[0..len], expected[gap..][0..len]);

            move(u8, buf[0..len], buf[gap..][0..len]);
            try testing.expectEqualSlices(
                u8,
                expected[0..len],
                buf[0..len],
            );
        }
    }.run, .{
        .corpus = &.{
            "",
            &.{ 100, 10, 0x42 },
            &.{ 64, 1, 0xFF },
        },
    });
}

test "fuzz move backward" {
    try testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 3) return;
            const len: usize = @min(input[0], 200);
            const gap: usize = @min(input[1], 100);
            if (len == 0) return;

            var buf: [512]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i ^ ~input[2]);

            var expected = buf;
            @memmove(expected[gap..][0..len], expected[0..len]);

            move(u8, buf[gap..][0..len], buf[0..len]);
            try testing.expectEqualSlices(
                u8,
                expected[gap..][0..len],
                buf[gap..][0..len],
            );
        }
    }.run, .{
        .corpus = &.{
            "",
            &.{ 100, 10, 0x42 },
            &.{ 64, 1, 0xFF },
        },
    });
}

// ---------------------------------------------------------------------------
// Extended deterministic tests
// ---------------------------------------------------------------------------

test "copy: large sizes across alignment peel threshold" {
    // Exercises copyLargeForward with multiple loop iterations and the
    // alignment peel path (copy_align_peel_min = stride * 2).
    const large_sizes = [_]usize{
        stride * 2,
        stride * 2 + 1,
        stride * 3,
        stride * 3 - 1,
        1024,
        2048,
        4096,
        8192,
        16384,
    };
    const offsets = [_]usize{ 0, 1, 3, chunk_bytes / 2, chunk_bytes - 1 };

    for (large_sizes) |len| {
        for (offsets) |src_off| {
            for (offsets) |dst_off| {
                var src_buf: [16384 + chunk_bytes]u8 align(64) = undefined;
                for (&src_buf, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);

                var dst_buf: [16384 + chunk_bytes]u8 align(64) = undefined;
                @memset(&dst_buf, 0xCD);

                const src = src_buf[src_off..][0..len];
                const dst = dst_buf[dst_off..][0..len];

                copy(u8, dst, src);
                try testing.expectEqualSlices(u8, src, dst);
            }
        }
    }
}

test "move: large forward across peel threshold" {
    // move_forward_align_peel_min = @max(stride * 2, 2048), so we need
    // sizes around and above 2048 with small gaps.
    const large_sizes = [_]usize{ 1024, 2048, 2049, 3000, 4096, 8192, 16384 };
    const gaps = [_]usize{ 1, 3, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, 63 };

    for (large_sizes) |len| {
        for (gaps) |gap| {
            var buf: [16384 + 64]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i *% 53 +% 7);

            var expected = buf;
            @memmove(expected[0..len], expected[gap..][0..len]);

            move(u8, buf[0..len], buf[gap..][0..len]);
            try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
        }
    }
}

test "move: large backward across peel threshold" {
    const large_sizes = [_]usize{ 1024, 2048, 2049, 3000, 4096, 8192, 16384 };
    const gaps = [_]usize{ 1, 3, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, 63 };

    for (large_sizes) |len| {
        for (gaps) |gap| {
            var buf: [16384 + 64]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i *% 53 +% 7);

            var expected = buf;
            @memmove(expected[gap..][0..len], expected[0..len]);

            move(u8, buf[gap..][0..len], buf[0..len]);
            try testing.expectEqualSlices(
                u8,
                expected[gap..][0..len],
                buf[gap..][0..len],
            );
        }
    }
}

test "move: non-overlapping regions" {
    // move() with disjoint src/dest should produce the same result as copy().
    const sizes = [_]usize{ 0, 1, 7, 16, 64, 256, 1024, 4096 };
    for (sizes) |len| {
        var src: [4096]u8 = undefined;
        for (&src, 0..) |*b, i| b.* = @truncate(i *% 41);

        var dest: [4096]u8 = .{0xAA} ** 4096;
        move(u8, dest[0..len], src[0..len]);
        try testing.expectEqualSlices(u8, src[0..len], dest[0..len]);
    }
}

test "move: identity (dest == src)" {
    const sizes = [_]usize{ 0, 1, 3, 8, 16, 63, 64, 128, 256, 1024, 4096 };
    for (sizes) |len| {
        var buf: [4096]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i *% 71 +% 3);

        const expected = buf;
        move(u8, buf[0..len], buf[0..len]);
        try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
    }
}

test "copy: zero-length for various types" {
    var u8_buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    copy(u8, u8_buf[0..0], u8_buf[4..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &u8_buf);

    var u32_buf = [_]u32{ 10, 20, 30, 40 };
    copy(u32, u32_buf[0..0], u32_buf[2..2]);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40 }, &u32_buf);

    var u64_buf = [_]u64{ 100, 200 };
    copy(u64, u64_buf[0..0], u64_buf[1..1]);
    try testing.expectEqualSlices(u64, &.{ 100, 200 }, &u64_buf);
}

test "move: zero-length for various types" {
    var u8_buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    move(u8, u8_buf[0..0], u8_buf[4..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &u8_buf);

    var u32_buf = [_]u32{ 10, 20, 30, 40 };
    move(u32, u32_buf[0..0], u32_buf[2..2]);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40 }, &u32_buf);
}

test "copy: multi-type elements" {
    // u16
    {
        var src = [_]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };
        var dst: [8]u16 = undefined;
        copy(u16, &dst, &src);
        try testing.expectEqualSlices(u16, &src, &dst);
    }
    // u64
    {
        const len = 128;
        var src: [len]u64 = undefined;
        for (&src, 0..) |*v, i| v.* = @as(u64, i) *% 0xDEADBEEFCAFEBABE +% 1;
        var dst: [len]u64 = undefined;
        copy(u64, &dst, &src);
        try testing.expectEqualSlices(u64, &src, &dst);
    }
    // u128
    {
        const len = 32;
        var src: [len]u128 = undefined;
        for (&src, 0..) |*v, i| v.* = @as(u128, i) *% 0xFEDCBA9876543210FEDCBA9876543210 +% 1;
        var dst: [len]u128 = undefined;
        copy(u128, &dst, &src);
        try testing.expectEqualSlices(u128, &src, &dst);
    }
}

test "move: large overlap matrix" {
    // Extends the existing overlap matrix to cover multiple loop iterations.
    const max_len = stride * 4 + chunk_bytes;
    const max_gap = chunk_bytes * 2;
    const buf_len = max_len + max_gap;

    var base: [buf_len]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @truncate(i *% 29 +% 11);

    // Test a selection of lengths to keep runtime reasonable.
    const test_lens = [_]usize{
        0,              1,          chunk_bytes - 1, chunk_bytes,    chunk_bytes + 1,
        stride - 1,     stride,     stride + 1,      stride * 2 - 1, stride * 2,
        stride * 2 + 1, stride * 3, stride * 4,      max_len,
    };
    const test_gaps = [_]usize{
        0, 1, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, max_gap,
    };

    for (test_lens) |len| {
        for (test_gaps) |gap| {
            if (len + gap > buf_len) continue;

            // Forward: dest < src.
            {
                var buf = base;
                var expected = base;
                @memmove(expected[0..len], expected[gap..][0..len]);
                move(u8, buf[0..len], buf[gap..][0..len]);
                try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
            }
            // Backward: dest > src.
            {
                var buf = base;
                var expected = base;
                @memmove(expected[gap..][0..len], expected[0..len]);
                move(u8, buf[gap..][0..len], buf[0..len]);
                try testing.expectEqualSlices(
                    u8,
                    expected[gap..][0..len],
                    buf[gap..][0..len],
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Extended fuzz tests (wider input ranges)
// ---------------------------------------------------------------------------

test "fuzz copy large" {
    try testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 4) return;
            // Parse 2 bytes as little-endian u16 for length, cap at 8192.
            const raw_len = @as(u16, input[0]) | (@as(u16, input[1]) << 8);
            const len: usize = @min(raw_len, 8192);
            const src_off: usize = input[2] & 0x3F; // 0..63
            const dst_off: usize = input[3] & 0x3F;

            var src_buf: [8192 + 64]u8 = undefined;
            const seed: u8 = if (input.len > 4) input[4] else 0;
            for (&src_buf, 0..) |*b, i| b.* = @truncate(i *% 131 +% seed);

            var dst_buf: [8192 + 64]u8 = .{0xAA} ** (8192 + 64);

            const src = src_buf[src_off..][0..len];
            const dst = dst_buf[dst_off..][0..len];

            copy(u8, dst, src);
            try testing.expectEqualSlices(u8, src, dst);
        }
    }.run, .{
        .corpus = &.{
            "", // skipped (< 4 bytes)
            &.{ 0, 0, 0, 0 }, // len=0
            &.{ 64, 0, 0, 0 }, // len=64 aligned
            &.{ 64, 0, 1, 3 }, // len=64 misaligned
            &.{ 0, 8, 0, 0 }, // len=2048
            &.{ 0, 16, 7, 15 }, // len=4096 misaligned
            &.{ 0, 32, 0, 0, 0x42 }, // len=8192
        },
    });
}

test "fuzz move large" {
    try testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 4) return;
            const raw_len = @as(u16, input[0]) | (@as(u16, input[1]) << 8);
            const len: usize = @min(raw_len, 8192);
            const gap: usize = @min(input[2], 128);
            const direction = input[3] & 1; // 0 = forward, 1 = backward
            if (len == 0) return;

            const buf_size = 8192 + 129;
            var buf: [buf_size]u8 = undefined;
            const seed: u8 = if (input.len > 4) input[4] else 0;
            for (&buf, 0..) |*b, i| b.* = @truncate(i *% 131 +% seed);

            if (len + gap > buf_size) return;

            var expected = buf;
            if (direction == 0) {
                // Forward: dest = buf[0..len], src = buf[gap..][0..len]
                @memmove(expected[0..len], expected[gap..][0..len]);
                move(u8, buf[0..len], buf[gap..][0..len]);
                try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
            } else {
                // Backward: dest = buf[gap..][0..len], src = buf[0..len]
                @memmove(expected[gap..][0..len], expected[0..len]);
                move(u8, buf[gap..][0..len], buf[0..len]);
                try testing.expectEqualSlices(
                    u8,
                    expected[gap..][0..len],
                    buf[gap..][0..len],
                );
            }
        }
    }.run, .{
        .corpus = &.{
            "",
            &.{ 0, 8, 1, 0, 0x42 }, // len=2048, gap=1, forward
            &.{ 0, 8, 1, 1, 0x42 }, // len=2048, gap=1, backward
            &.{ 0, 16, 15, 0 }, // len=4096, gap=15, forward
            &.{ 0, 16, 15, 1 }, // len=4096, gap=15, backward
            &.{ 0, 32, 0, 0 }, // len=8192, gap=0 (identity)
            &.{ 64, 0, 63, 0 }, // len=64, gap=63, forward
        },
    });
}
