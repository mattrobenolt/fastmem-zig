//! Differential public-API fuzzers with independent byte-loop oracles.
const std = @import("std");
const testing = std.testing;
const fastmem = @import("../root.zig");

const max_len = 64 * 1024;
const max_gap = 16 * 1024;
const padding = 128;

fn reference(dest: []u8, source: []const u8) void {
    @disableIntrinsics();
    for (dest, source) |*d, value| d.* = value;
}

test "fuzz copy with independent offsets and canaries" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const len = smith.valueRangeAtMost(u32, 0, max_len);
            const src_offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const dst_offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            var source: [max_len + padding]u8 = undefined;
            var actual: [max_len + padding]u8 = undefined;
            smith.bytes(&source);
            smith.bytes(&actual);
            const source_before = source;
            var expected = actual;
            reference(expected[dst_offset..][0..len], source[src_offset..][0..len]);
            fastmem.copy(u8, actual[dst_offset..][0..len], source[src_offset..][0..len]);
            try testing.expectEqualSlices(u8, &expected, &actual);
            try testing.expectEqualSlices(u8, &source_before, &source);
        }
    }.run, .{ .corpus = &.{ "", &.{ 0, 0, 1, 0, 63, 17 }, &.{ 255, 255, 0, 0, 1, 63 } } });
}

test "fuzz move with wide gaps independent offsets and canaries" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const len = smith.valueRangeAtMost(u32, 0, max_len);
            const gap = smith.valueRangeAtMost(u32, 0, max_gap);
            const src_offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const dst_offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            // Independent low bits survive except at the maximum displacement boundary.
            const high = @min(gap + dst_offset, src_offset + max_gap);
            var original: [max_len + max_gap + padding]u8 = undefined;
            smith.bytes(&original);
            inline for (.{ false, true }) |reverse| {
                const source = if (reverse) high else src_offset;
                const dest = if (reverse) src_offset else high;
                var actual = original;
                var expected = original;
                reference(expected[dest..][0..len], original[source..][0..len]);
                fastmem.move(u8, actual[dest..][0..len], actual[source..][0..len]);
                try testing.expectEqualSlices(u8, &expected, &actual);
            }
        }
    }.run, .{ .corpus = &.{ "", &.{ 0, 0, 1, 0, 0, 64, 0, 0, 63, 17 }, &.{ 255, 255, 0, 0, 160, 15, 0, 0, 1, 63 } } });
}

test "fuzz set with destination canaries" {
    if (comptime !@hasDecl(fastmem, "set")) return error.SkipZigTest;
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const len = smith.valueRangeAtMost(u32, 0, max_len);
            const offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const value = smith.value(u8);
            var actual: [max_len + padding]u8 = undefined;
            smith.bytes(&actual);
            var expected = actual;
            for (expected[offset..][0..len]) |*byte| byte.* = value;
            fastmem.set(u8, actual[offset..][0..len], value);
            try testing.expectEqualSlices(u8, &expected, &actual);
        }
    }.run, .{ .corpus = &.{ "", &.{ 0, 32, 63, 0xff }, &.{ 0, 0, 0, 0 } } });
}
