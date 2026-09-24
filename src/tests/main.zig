//! Exhaustive Linux guard-page checks through the public API.
const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const Guarded = @import("Guarded.zig");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const json = std.json;
const Io = std.Io;
const process = std.process;

const Op = enum { copy, move, set };
const Case = struct {
    op: Op = .copy,
    source_order: enum { below, above, shared } = .below,
    len: u32 = 0,
    src: u32 = 0,
    dst: u32 = 0,
    gap: u32 = 0,
    side: Guarded.Side = .start,
    value: u8 = 0,
};
var current: Case = .{};
var count: u64 = 0;

comptime {
    // Calls below also pin argument types and the void return type.
    for (.{ "copy", "move", "set" }) |name| {
        if (@TypeOf(@field(fastmem.impl, name)) != []const u8)
            @compileError("fastmem.impl fields must be comptime strings");
    }
}

fn summary(status: []const u8, detail: []const u8, elapsed_ns: i96) void {
    var buffer: [2048]u8 = undefined;
    const c = @as(*volatile Case, &current).*;
    var writer: Io.Writer = .fixed(&buffer);
    json.Stringify.value(.{
        .schema = 1,
        .status = status,
        .cases = count,
        .elapsed_ns = elapsed_ns,
        .cpu = builtin.cpu.model.name,
        .optimize = @tagName(builtin.mode),
        .set_available = @hasDecl(fastmem, "set"),
        .impl = fastmem.impl,
        .detail = detail,
        .case = c,
    }, .{}, &writer) catch return;
    writer.writeByte('\n') catch return;
    const line = writer.buffered();
    _ = linux.write(1, line.ptr, line.len);
}

fn fault(_: posix.SIG) callconv(.c) void {
    summary("fail", "guard-page fault", 0);
    linux.exit_group(1);
}

pub fn main(init: process.Init) void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = fault },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.SEGV, &action, null);
    posix.sigaction(.BUS, &action, null);
    const start = Io.Timestamp.now(init.io, .awake);
    run(init.gpa) catch |err| {
        const elapsed = start.durationTo(Io.Timestamp.now(init.io, .awake)).nanoseconds;
        summary("fail", @errorName(err), elapsed);
        process.exit(1);
    };
    summary("pass", "", start.durationTo(Io.Timestamp.now(init.io, .awake)).nanoseconds);
}

// A byte-loop oracle stays independent of the kernel and compiler-rt exports.
fn pattern(bytes: []u8) void {
    @disableIntrinsics();
    for (bytes, 0..) |*byte, i| {
        var x: u64 = @as(u64, i) +% 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        byte.* = @truncate(x ^ (x >> 31));
    }
}

fn reference(dest: []u8, source: []const u8) void {
    @disableIntrinsics();
    for (dest, source) |*d, s| d.* = s;
}

fn fill(dest: []u8, value: u8) void {
    @disableIntrinsics();
    for (dest) |*d| d.* = value;
}

fn call(comptime op: Op, dest: []u8, source: []const u8, value: u8) void {
    const result: void = switch (op) {
        .copy => fastmem.copy(u8, dest, source),
        .move => fastmem.move(u8, dest, source),
        .set => if (@hasDecl(fastmem, "set")) fastmem.set(u8, dest, value),
    };
    _ = result;
}

fn check(comptime op: Op, src: Guarded, dst: Guarded, expected: []u8, c: Case) !void {
    @as(*volatile Case, &current).* = c;
    // Synthetic test bytes contain no secrets.
    @memset(dst.bytes, 0xa5);
    @memset(expected, 0xa5);
    const source = src.bytes[c.src..][0..c.len];
    const dest = dst.bytes[c.dst..][0..c.len];
    if (op == .set)
        fill(expected[c.dst..][0..c.len], c.value)
    else
        reference(expected[c.dst..][0..c.len], source);
    call(op, dest, source, c.value);
    if (!mem.eql(u8, expected, dst.bytes)) return error.DestinationOrCanaryMismatch;
    count += 1;
}

fn disjoint(src: Guarded, above: Guarded, dst: Guarded, expected: []u8, len: u32, offsets: u32) !void {
    inline for (.{ Guarded.Side.start, Guarded.Side.end }) |side| {
        for (0..offsets) |s| {
            for (0..offsets) |d| {
                var c: Case = .{
                    .len = len,
                    .src = src.offset(side, len, @intCast(s)),
                    .dst = dst.offset(side, len, @intCast(d)),
                    .side = side,
                };
                try check(.copy, src, dst, expected, c);
                c.op = .move;
                try check(.move, src, dst, expected, c);
                c.source_order = .above;
                try check(.move, above, dst, expected, c);
            }
        }
        if (comptime @hasDecl(fastmem, "set")) {
            for (0..offsets) |d| {
                for ([_]u8{ 0, 0x5a, 0xff }) |value| {
                    try check(.set, src, dst, expected, .{
                        .op = .set,
                        .len = len,
                        .src = 0,
                        .dst = dst.offset(side, len, @intCast(d)),
                        .side = side,
                        .value = value,
                    });
                }
            }
        }
    }
}

fn overlapOne(
    comptime side: Guarded.Side,
    comptime backward: bool,
    buf: Guarded,
    expected: []u8,
    original: []const u8,
    len: u32,
    gap: u32,
    inset: u32,
) !void {
    const base = buf.offset(side, len + gap, inset);
    const source = base + if (backward) @as(u32, 0) else gap;
    const dest = base + if (backward) gap else @as(u32, 0);
    const c: Case = .{
        .op = .move,
        .source_order = .shared,
        .len = len,
        .src = source,
        .dst = dest,
        .gap = gap,
        .side = side,
    };
    @as(*volatile Case, &current).* = c;
    reference(buf.bytes, original);
    reference(expected, original);
    reference(expected[dest..][0..len], original[source..][0..len]);
    call(.move, buf.bytes[dest..][0..len], buf.bytes[source..][0..len], 0);
    if (!mem.eql(u8, expected, buf.bytes)) return error.OverlapOrCanaryMismatch;
    count += 1;
}

fn overlap(buf: Guarded, expected: []u8, original: []const u8, len: u32, offsets: u32) !void {
    var gaps: [139]u32 = undefined;
    for (gaps[0..129], 0..) |*gap, i| gap.* = @intCast(i);
    const extra = [_]u32{ 3840, 3841, 3968, 4000, 4095, 4096, 4097, 8192, len / 2, len -| 1 };
    @memcpy(gaps[129..], &extra);
    const selected = gaps[0..@as(u32, if (len > 1024) 139 else 129)];
    inline for (.{ Guarded.Side.start, Guarded.Side.end }) |side| {
        for (selected) |gap| {
            for (0..offsets) |inset| {
                inline for (.{ false, true }) |backward| {
                    try overlapOne(side, backward, buf, expected, original, len, gap, @intCast(inset));
                }
            }
        }
    }
}

fn sizeClass(
    allocator: mem.Allocator,
    sizes: []const u32,
    offsets: u32,
    overlap_offsets: u32,
) !void {
    var maximum: u32 = 0;
    for (sizes) |len| maximum = @max(maximum, len);
    const capacity = maximum + @max(256, if (maximum > 1024) @max(8192, maximum - 1) + 64 else 0);
    var windows: [3]Guarded = undefined;
    var initialized: u32 = 0;
    defer for (windows[0..initialized]) |window| window.deinit();
    for (&windows) |*window| {
        window.* = try Guarded.init(capacity);
        initialized += 1;
    }
    // mmap placement is not an API guarantee. Sort addresses before choosing the destination.
    mem.sort(Guarded, &windows, {}, struct {
        fn less(_: void, a: Guarded, b: Guarded) bool {
            return @intFromPtr(a.bytes.ptr) < @intFromPtr(b.bytes.ptr);
        }
    }.less);
    const src = windows[0];
    const dst = windows[1];
    const above = windows[2];
    const expected = try allocator.alloc(u8, dst.bytes.len);
    defer allocator.free(expected);
    const original = try allocator.alloc(u8, src.bytes.len);
    defer allocator.free(original);
    pattern(original);
    for ([_]Guarded{ src, above }) |source| {
        reference(source.bytes, original);
        // A read-only source detects writes even when the final bytes look correct.
        const rc = linux.mprotect(source.bytes.ptr, source.bytes.len, .{ .READ = true });
        if (linux.errno(rc) != .SUCCESS) return error.ProtectFailed;
    }
    for (sizes) |len| {
        try disjoint(src, above, dst, expected, len, offsets);
        try overlap(dst, expected, original, len, overlap_offsets);
    }
}

fn run(allocator: mem.Allocator) !void {
    var small: [1025]u32 = undefined;
    for (&small, 0..) |*len, i| len.* = @intCast(i);
    try sizeClass(allocator, &small, 64, 1);
    // Each large size gets its own page-rounded window, not a 1 MiB small-case mapping.
    var power: u32 = 1024;
    while (power <= 1024 * 1024) : (power *= 2) {
        for ([_]u32{ power - 1, power, power + 1 }) |len| {
            if (len > 1024 * 1024) continue;
            try sizeClass(allocator, &.{len}, 2, 1);
        }
    }
    for ([_]u32{ 4095, 4096, 4097 }) |base| {
        var multiplier: u32 = 1;
        while (base * multiplier <= 1024 * 1024) : (multiplier *= 2) {
            try sizeClass(allocator, &.{base * multiplier}, 2, 1);
        }
    }
}
