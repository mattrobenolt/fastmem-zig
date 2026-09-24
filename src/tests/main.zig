//! Exhaustive Linux guard-page checks through the public API.
const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const Guarded = @import("Guarded.zig");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const process = std.process;

const Op = enum { copy, move, set };
const Case = struct {
    op: Op = .copy,
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
    const line = fmt.bufPrint(
        &buffer,
        "{{\"schema\":1,\"status\":\"{s}\",\"cases\":{d},\"elapsed_ns\":{d}," ++
            "\"cpu\":\"{s}\",\"optimize\":\"{s}\",\"set_available\":{}," ++
            "\"impl\":{{\"copy\":\"{s}\",\"move\":\"{s}\",\"set\":\"{s}\"}}," ++
            "\"detail\":\"{s}\",\"case\":{{\"op\":\"{s}\",\"len\":{d},\"src\":{d}," ++
            "\"dst\":{d},\"gap\":{d},\"side\":\"{s}\",\"value\":{d}}}}}\n",
        .{
            status,                   count,             elapsed_ns,        builtin.cpu.model.name, @tagName(builtin.mode),
            @hasDecl(fastmem, "set"), fastmem.impl.copy, fastmem.impl.move, fastmem.impl.set,       detail,
            @tagName(c.op),           c.len,             c.src,             c.dst,                  c.gap,
            @tagName(c.side),         c.value,
        },
    ) catch return;
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
    for (bytes, 0..) |*byte, i| byte.* = @truncate((i *% 131 +% 17) ^ (i >> 8));
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

fn disjoint(src: Guarded, dst: Guarded, expected: []u8, len: u32, offsets: u32) !void {
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

fn overlap(buf: Guarded, expected: []u8, original: []const u8, len: u32, offsets: u32) !void {
    inline for (.{ Guarded.Side.start, Guarded.Side.end }) |side| {
        for (0..129) |gap_index| {
            const gap: u32 = @intCast(gap_index);
            for (0..offsets) |inset| {
                inline for (.{ false, true }) |backward| {
                    const base = buf.offset(side, len + gap, @intCast(inset));
                    const s = base + if (backward) @as(u32, 0) else gap;
                    const d = base + if (backward) gap else @as(u32, 0);
                    const c: Case = .{
                        .op = .move,
                        .len = len,
                        .src = s,
                        .dst = d,
                        .gap = gap,
                        .side = side,
                    };
                    @as(*volatile Case, &current).* = c;
                    reference(buf.bytes, original);
                    reference(expected, original);
                    reference(expected[d..][0..len], original[s..][0..len]);
                    call(.move, buf.bytes[d..][0..len], buf.bytes[s..][0..len], 0);
                    if (!mem.eql(u8, expected, buf.bytes)) return error.OverlapOrCanaryMismatch;
                    count += 1;
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
    const src = try Guarded.init(maximum + 256);
    defer src.deinit();
    const dst = try Guarded.init(maximum + 256);
    defer dst.deinit();
    const expected = try allocator.alloc(u8, dst.bytes.len);
    defer allocator.free(expected);
    const original = try allocator.alloc(u8, src.bytes.len);
    defer allocator.free(original);
    pattern(original);
    reference(src.bytes, original);
    // A read-only source detects writes even when the final bytes look correct.
    if (linux.errno(linux.mprotect(src.bytes.ptr, src.bytes.len, .{ .READ = true })) != .SUCCESS)
        return error.ProtectFailed;
    for (sizes) |len| {
        try disjoint(src, dst, expected, len, offsets);
        try overlap(dst, expected, original, len, overlap_offsets);
    }
}

fn run(allocator: mem.Allocator) !void {
    var small: [1025]u32 = undefined;
    for (&small, 0..) |*len, i| len.* = @intCast(i);
    try sizeClass(allocator, &small, 64, 1);
    // Each large size gets its own page-rounded window, not a 1 MiB small-case mapping.
    var power: u32 = 2048;
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
