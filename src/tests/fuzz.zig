//! Differential set fuzzing joins the existing copy and move fuzzers.
const std = @import("std");
const testing = std.testing;
const fastmem = @import("../root.zig");

test "fuzz set with destination canaries" {
    if (comptime !@hasDecl(fastmem, "set")) return error.SkipZigTest;
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const len: u32 = smith.valueRangeAtMost(u16, 0, 8192);
            const offset: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const value = smith.value(u8);
            var actual: [8192 + 128]u8 = undefined;
            smith.bytes(&actual);
            var expected = actual;
            for (expected[offset..][0..len]) |*byte| byte.* = value;
            fastmem.set(u8, actual[offset..][0..len], value);
            try testing.expectEqualSlices(u8, &expected, &actual);
        }
    }.run, .{ .corpus = &.{ "", &.{ 0, 32, 63, 0xff }, &.{ 0, 0, 0, 0 } } });
}
