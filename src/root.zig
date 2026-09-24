//! Fast memory operations using native SIMD vectors.
//!
//! `memcpy` and `memmove` now live in separate modules so their policy
//! decisions can diverge cleanly, while still sharing the low-level
//! load/store primitives and the overlap-safe forward kernel.

const std = @import("std");
const testing = std.testing;

const common = @import("common.zig");
const chunk_bytes = common.chunk_bytes;
const stride = common.stride;
const memcpy_impl = @import("memcpy.zig");
pub const CopyFlags = memcpy_impl.Flags;
const memmove_impl = @import("memmove.zig");
pub const MoveFlags = memmove_impl.Flags;

/// Public snapshot of the current memcpy and memmove tuning knobs.
pub const Flags = struct {
    copy: CopyFlags,
    move: MoveFlags,
};

pub const flags: Flags = .{
    .copy = memcpy_impl.flags,
    .move = memmove_impl.flags,
};

/// Comptime kernel identifiers for correctness and benchmark reports.
pub const impl = .{
    .copy = @as([]const u8, "zig-simd"),
    .move = @as([]const u8, "zig-simd"),
    .set = @as([]const u8, "unavailable"),
};

test {
    _ = @import("tests/fuzz.zig");
}

pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    memcpy_impl.copy(T, dest, source);
}

pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    memmove_impl.move(T, dest, source);
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
