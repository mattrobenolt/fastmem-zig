//! Focused class, overlap, and dispatch regressions supplement the guard matrix.
const std = @import("std");
const testing = std.testing;
const move = @import("move.zig");
const set = @import("set.zig");

fn pattern(bytes: []u8) void {
    @disableIntrinsics();
    for (bytes, 0..) |*byte, i| {
        var value: u64 = i +% 0x9e3779b97f4a7c15;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        byte.* = @truncate(value ^ (value >> 31));
    }
}

const lengths = [_]u32{
    0,     1,   2,   3,   4,   7,   8,    15,   16,   31,   32,   63,   64,   65,   127,   128,   129,
    255,   256, 257, 511, 512, 513, 1023, 1024, 1025, 2048, 2049, 4095, 4096, 4097, 16383, 16384, 16385,
    32768,
};
const capacity = 32768 + 8192 + 64;

test "x86: class edges and 4K alias overlap in both directions" {
    var original: [capacity]u8 align(64) = undefined;
    pattern(&original);
    for (lengths) |n| {
        for ([_]u32{ 0, 1, 31, 33, 63, 64, 128, 255, 256, 3840, 3841, 3968, 4000, 4095, 4096, 4097, 8192 }) |gap| {
            for ([_]u32{ 0, 1, 31, 63 }) |offset| {
                for ([_]bool{ false, true }) |backward| {
                    var got = original;
                    var expected = original;
                    const source = offset + if (backward) @as(u32, 0) else gap;
                    const dest = offset + if (backward) gap else @as(u32, 0);
                    for (0..n) |i| expected[dest + i] = original[source + i];
                    const result = move.kernel(got[dest..].ptr, got[source..].ptr, n);
                    try testing.expectEqual(@as(?*anyopaque, @ptrCast(got[dest..].ptr)), result);
                    try testing.expectEqualSlices(u8, &expected, &got);
                }
            }
        }
    }
}

test "x86: disjoint alias residues and libc memset byte conversion" {
    var original: [capacity]u8 align(4096) = undefined;
    pattern(&original);
    var got: [capacity]u8 align(4096) = undefined;
    for (lengths) |n| {
        for ([_]u32{ 0, 1, 255, 256, 511, 512, 1024 }) |offset| {
            @memset(&got, 0xa5); // Synthetic canaries contain no secrets.
            _ = move.kernel(got[offset..].ptr, &original, n);
            try testing.expectEqualSlices(u8, original[0..n], got[offset..][0..n]);
            for (got[0..offset]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
            for (got[offset + n ..]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
            for ([_]c_int{ 0, -1, 0x12345a }) |value| {
                @memset(&got, 0xa5); // Synthetic canaries contain no secrets.
                const result = set.kernel(got[offset..].ptr, value, n);
                try testing.expectEqual(@as(?*anyopaque, @ptrCast(got[offset..].ptr)), result);
                for (got[offset..][0..n]) |byte| {
                    try testing.expectEqual(@as(u8, @truncate(@as(c_uint, @bitCast(value)))), byte);
                }
                for (got[0..offset]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
                for (got[offset + n ..]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
            }
        }
    }
    try testing.expectEqual(@as(?*anyopaque, null), move.kernel(null, null, 0));
    try testing.expectEqual(@as(?*anyopaque, null), set.kernel(null, -1, 0));
}
