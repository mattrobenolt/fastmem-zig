//! Measurement binary for the fastmem benchmark fleet.
//!
//! stdout is JSONL (schema v1, see docs/bench-design.md). stderr is free
//! text diagnostics. The binary measures; it does not format for humans.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const simd = std.simd;
const assert = std.debug.assert;
const builtin = @import("builtin");

const bench_options = @import("bench_options");
const fastmem = @import("fastmem");

const has_libc: bool = bench_options.link_libc;
const rev: []const u8 = bench_options.rev;

// Keep in sync with src/common.zig.
const chunk_bytes = @min(simd.suggestVectorLength(u8) orelse 16, 32);

const seed_target_bytes_per_case = 32 * 1024 * 1024;
const iterations_seed_min = 256;
const iterations_seed_max = 4_000_000;
const iterations_hard_max = 64 * 1024 * 1024;

const standard_sizes = [_]usize{
    0,     1,     2,      3,      4,      7,      8,      15,
    16,    24,    31,     32,     48,     63,     64,     96,
    127,   128,   192,    255,    256,    384,    511,    512,
    768,   1024,  2048,   4096,   8192,   16384,  65536,  262144,
    1048576,
};

const quick_sizes = [_]usize{ 8, 32, 64, 256, 1024, 4096, 16384, 262144 };

const move_gaps = [_]usize{ 1, chunk_bytes - 1, chunk_bytes + 1 };

const CopyProfile = struct {
    name: []const u8,
    src_off: usize,
    dst_off: usize,
};

const copy_profiles = [_]CopyProfile{
    .{ .name = "aligned", .src_off = 0, .dst_off = 0 },
    .{ .name = "misaligned", .src_off = 1, .dst_off = 3 },
    .{
        .name = "cross-lane",
        .src_off = chunk_bytes - 1,
        .dst_off = chunk_bytes / 2,
    },
};

const Op = enum { copy, move };
const Impl = enum { builtin, fastmem, libc };
const Suite = enum { quick, standard, dist };
const MoveDirection = enum { fwd, bwd };

// The benchmark calls every implementation through one of these exported
// entry points, invoked with @call(.never_inline) at the loop site (0.16
// grammar cannot combine export and noinline on the declaration). The
// symbols are therefore intact in the binary for the harness to disassemble,
// and the loop really executes them.
export fn fastmem_copy(dst: [*]u8, src: [*]const u8, len: usize) void {
    fastmem.copy(u8, dst[0..len], src[0..len]);
}

export fn fastmem_move(dst: [*]u8, src: [*]const u8, len: usize) void {
    fastmem.move(u8, dst[0..len], src[0..len]);
}

export fn builtin_memcpy(dst: [*]u8, src: [*]const u8, len: usize) void {
    @memcpy(dst[0..len], src[0..len]);
}

export fn builtin_memmove(dst: [*]u8, src: [*]const u8, len: usize) void {
    @memmove(dst[0..len], src[0..len]);
}

extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

fn libcMemcpy(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) void {
    _ = memcpy(dst, src, len);
}

fn libcMemmove(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) void {
    _ = memmove(dst, src, len);
}

const OpFn = fn (dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) void;

// The libc externs are only linked when has_libc. Map the libc slot to a
// harmless function otherwise so comptime instantiation of every Impl
// branch stays valid; the CLI never selects libc in a no-libc build.
fn copyFnFor(comptime impl: Impl) OpFn {
    return switch (impl) {
        .builtin => builtin_memcpy,
        .fastmem => fastmem_copy,
        .libc => if (has_libc) libcMemcpy else builtin_memcpy,
    };
}

fn moveFnFor(comptime impl: Impl) OpFn {
    return switch (impl) {
        .builtin => builtin_memmove,
        .fastmem => fastmem_move,
        .libc => if (has_libc) libcMemmove else builtin_memmove,
    };
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

const CopyCase = struct {
    id: []const u8,
    profile: []const u8,
    size: usize,
    src_off: usize,
    dst_off: usize,
};

const Case = union(enum) {
    copy: CopyCase,

    fn id(self: Case) []const u8 {
        return switch (self) {
            .copy => |c| c.id,
        };
    }
};

// ---------------------------------------------------------------------------
// Config / CLI
// ---------------------------------------------------------------------------

const max_filters = 8;

const Config = struct {
    suite: Suite = .standard,
    filters: [max_filters][]const u8 = undefined,
    n_filters: usize = 0,
    impls: [3]Impl = undefined,
    n_impls: usize = 0,
    samples: usize = 5,
    sample_ms: u64 = 20,
    warmup_ms: u64 = 10,
    seed: u64 = 1,
    list: bool = false,

    fn sampleNs(self: *const Config) u64 {
        return self.sample_ms * std.time.ns_per_ms;
    }

    fn warmupNs(self: *const Config) u64 {
        return self.warmup_ms * std.time.ns_per_ms;
    }

    fn matches(self: *const Config, case_id: []const u8) bool {
        if (self.n_filters == 0) return true;
        for (self.filters[0..self.n_filters]) |f| {
            if (mem.find(u8, case_id, f) != null) return true;
        }
        return false;
    }
};

const usage_text =
    \\usage: bench-fastmem [--suite quick|standard|dist] [--filter <substring>]
    \\                      [--impl builtin,fastmem,libc] [--samples N]
    \\                      [--sample-ms M] [--warmup-ms W] [--seed S] [--list]
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench-fastmem: " ++ fmt ++ "\n", args);
    std.debug.print("{s}", .{usage_text});
    std.process.exit(1);
}

fn takeValue(args: []const [:0]const u8, i: *usize, flag: []const u8) []const u8 {
    const arg = args[i.*];
    if (mem.find(u8, arg, "=")) |eq| return arg[eq + 1 ..];
    i.* += 1;
    if (i.* >= args.len) fail("flag {s} needs a value", .{flag});
    return args[i.*];
}

fn parseUsize(value: []const u8, flag: []const u8) usize {
    return std.fmt.parseInt(usize, value, 10) catch
        fail("flag {s} wants an integer, got '{s}'", .{ flag, value });
}

fn parseImpls(value: []const u8, cfg: *Config) void {
    var n: usize = 0;
    var it = mem.splitScalar(u8, value, ',');
    while (it.next()) |name| {
        const impl = std.meta.stringToEnum(Impl, name) orelse
            fail("unknown impl '{s}'", .{name});
        if (impl == .libc and !has_libc)
            fail("impl 'libc' not available: build with -Dlink-libc=true", .{});
        if (n >= cfg.impls.len) fail("too many impls", .{});
        cfg.impls[n] = impl;
        n += 1;
    }
    if (n == 0) fail("--impl needs at least one impl", .{});
    cfg.n_impls = n;
}

fn parseArgs(args: []const [:0]const u8) Config {
    var cfg: Config = .{};
    var impls_set = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const flag = if (mem.find(u8, arg, "=")) |eq| arg[0..eq] else arg;

        if (mem.eql(u8, flag, "--suite")) {
            const value = takeValue(args, &i, "--suite");
            cfg.suite = std.meta.stringToEnum(Suite, value) orelse
                fail("unknown suite '{s}'", .{value});
        } else if (mem.eql(u8, flag, "--filter")) {
            if (cfg.n_filters >= max_filters) fail("too many --filter flags", .{});
            cfg.filters[cfg.n_filters] = takeValue(args, &i, "--filter");
            cfg.n_filters += 1;
        } else if (mem.eql(u8, flag, "--impl")) {
            parseImpls(takeValue(args, &i, "--impl"), &cfg);
            impls_set = true;
        } else if (mem.eql(u8, flag, "--samples")) {
            cfg.samples = parseUsize(takeValue(args, &i, "--samples"), "--samples");
            if (cfg.samples == 0) fail("--samples must be >= 1", .{});
        } else if (mem.eql(u8, flag, "--sample-ms")) {
            cfg.sample_ms = parseUsize(takeValue(args, &i, "--sample-ms"), "--sample-ms");
            if (cfg.sample_ms == 0) fail("--sample-ms must be >= 1", .{});
        } else if (mem.eql(u8, flag, "--warmup-ms")) {
            cfg.warmup_ms = parseUsize(takeValue(args, &i, "--warmup-ms"), "--warmup-ms");
        } else if (mem.eql(u8, flag, "--seed")) {
            cfg.seed = parseUsize(takeValue(args, &i, "--seed"), "--seed");
        } else if (mem.eql(u8, flag, "--list")) {
            cfg.list = true;
        } else {
            fail("unknown argument '{s}'", .{arg});
        }
    }

    if (!impls_set) {
        cfg.impls = .{ .builtin, .fastmem, .libc };
        cfg.n_impls = if (has_libc) 3 else 2;
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// JSONL output
// ---------------------------------------------------------------------------

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeOptU64(w: *Io.Writer, value: ?u64) !void {
    if (value) |v| {
        try w.print("{d}", .{v});
    } else {
        try w.writeAll("null");
    }
}

fn emitMeta(w: *Io.Writer, cfg: *const Config) !void {
    try w.writeAll("{\"type\":\"meta\",\"schema\":1,\"rev\":");
    try writeJsonString(w, rev);
    try w.print(",\"zig\":\"{s}\",\"target\":\"{s}-{s}-{s}\",\"cpu\":\"{s}\"", .{
        builtin.zig_version_string,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.target.cpu.model.name,
    });
    try w.print(",\"optimize\":\"{s}\",\"link_libc\":{},\"chunk_bytes\":{d}", .{
        @tagName(builtin.mode),
        has_libc,
        chunk_bytes,
    });
    try w.print(",\"suite\":\"{s}\",\"seed\":{d},\"samples\":{d}", .{
        @tagName(cfg.suite),
        cfg.seed,
        cfg.samples,
    });
    try w.print(",\"sample_ms\":{d},\"warmup_ms\":{d},\"impls\":[", .{
        cfg.sample_ms,
        cfg.warmup_ms,
    });
    for (cfg.impls[0..cfg.n_impls], 0..) |impl, j| {
        if (j > 0) try w.writeByte(',');
        try writeJsonString(w, @tagName(impl));
    }
    // perf wiring lands in the next step.
    try w.writeAll("],\"perf\":{\"available\":false,\"events\":[],\"error\":null}}\n");
}

fn emitCaseLine(w: *Io.Writer, case: Case) !void {
    try w.writeAll("{\"type\":\"case\",\"case\":");
    try writeJsonString(w, case.id());
    switch (case) {
        .copy => |c| {
            try w.writeAll(",\"op\":\"copy\",\"profile\":");
            try writeJsonString(w, c.profile);
            try w.print(",\"size\":{d},\"src_off\":{d},\"dst_off\":{d},\"gap\":null", .{
                c.size,
                c.src_off,
                c.dst_off,
            });
        },
    }
    try w.writeAll("}\n");
}

fn emitSample(
    w: *Io.Writer,
    case: Case,
    size_json: []const u8,
    src_off: ?usize,
    dst_off: ?usize,
    gap: ?usize,
    impl: Impl,
    sample: usize,
    r: RunResult,
) !void {
    try w.writeAll("{\"type\":\"sample\",\"case\":");
    try writeJsonString(w, case.id());
    try w.writeAll(",\"op\":");
    switch (case) {
        .copy => |c| {
            try w.writeAll("\"copy\",\"profile\":");
            try writeJsonString(w, c.profile);
        },
    }
    try w.print(",\"size\":{s}", .{size_json});
    try w.writeAll(",\"src_off\":");
    try writeOptU64(w, src_off);
    try w.writeAll(",\"dst_off\":");
    try writeOptU64(w, dst_off);
    try w.writeAll(",\"gap\":");
    try writeOptU64(w, gap);
    try w.print(",\"impl\":\"{s}\",\"sample\":{d},\"iters\":{d},\"ns\":{d}", .{
        @tagName(impl),
        sample,
        r.iters,
        r.ns,
    });
    // perf wiring lands in the next step.
    try w.writeAll(",\"cycles\":null,\"instructions\":null,\"ref_cycles\":null}\n");
}

// ---------------------------------------------------------------------------
// Measurement loops
// ---------------------------------------------------------------------------

const RunResult = struct {
    ns: u64,
    iters: usize,
    checksum: u64,
};

fn fillPattern(buffer: []u8, seed: u8) void {
    for (buffer, 0..) |*b, i| {
        b.* = @truncate(i * 131 + seed);
    }
}

fn mapBytes(len: usize) ![]align(std.heap.page_size_min) u8 {
    return std.posix.mmap(
        null,
        @max(len, 1),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
}

fn runCopyFixed(
    comptime op: OpFn,
    io: Io,
    src_buf: []u8,
    dst_buf: []u8,
    size: usize,
    src_off: usize,
    dst_off: usize,
    iters: usize,
) RunResult {
    const source: []const u8 = src_buf[src_off..][0..size];
    const dest: []u8 = dst_buf[dst_off..][0..size];

    var checksum: u64 = 0;
    var index: usize = 0;

    const start = Io.Timestamp.now(io, .awake);
    for (0..iters) |i| {
        @call(.never_inline, op, .{ dest.ptr, source.ptr, size });
        if (size > 0) {
            checksum +%= dest[index];
            src_buf[src_off + index] +%= @truncate(i +% 1);
            index += 1;
            if (index == size) index = 0;
        }
    }
    const ns: u64 = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);

    mem.doNotOptimizeAway(src_buf);
    mem.doNotOptimizeAway(dst_buf);
    mem.doNotOptimizeAway(checksum);

    return .{ .ns = ns, .iters = iters, .checksum = checksum };
}

// ---------------------------------------------------------------------------
// Iteration calibration
// ---------------------------------------------------------------------------

fn seedIterations(size: usize) usize {
    const safe_size = @max(size, 1);
    return math.clamp(
        seed_target_bytes_per_case / safe_size,
        iterations_seed_min,
        iterations_seed_max,
    );
}

fn scaleIterations(iterations: usize, elapsed_ns: u64, target_ns: u64) usize {
    assert(iterations > 0);
    if (iterations >= iterations_hard_max) return iterations_hard_max;

    const doubled = if (iterations > iterations_hard_max / 2)
        iterations_hard_max
    else
        iterations * 2;
    if (elapsed_ns == 0) return doubled;

    // Add headroom so the next attempt typically clears target_ns.
    const target_with_headroom = target_ns + target_ns / 5;
    const scaled_u128 =
        (@as(u128, iterations) * @as(u128, target_with_headroom) +
            @as(u128, elapsed_ns) - 1) / @as(u128, elapsed_ns);
    var scaled: usize = if (scaled_u128 > iterations_hard_max)
        iterations_hard_max
    else
        @intCast(scaled_u128);

    if (scaled <= iterations) scaled = doubled;
    return @min(scaled, iterations_hard_max);
}

const Measured = struct {
    result: RunResult,
    iters: usize,
};

fn measuredSample(
    comptime run_fn: anytype,
    args: anytype,
    iters_start: usize,
    target_ns: u64,
) Measured {
    var iters = @max(iters_start, 1);
    while (true) {
        const r = @call(.auto, run_fn, args ++ .{iters});
        if (r.ns >= target_ns or iters >= iterations_hard_max) {
            return .{ .result = r, .iters = iters };
        }
        iters = scaleIterations(iters, r.ns, target_ns);
    }
}

// ---------------------------------------------------------------------------
// Case runner
// ---------------------------------------------------------------------------

fn runCase(
    cfg: *const Config,
    io: Io,
    w: *Io.Writer,
    case: Case,
    checksum_out: *u64,
) !void {
    var iters_state: [3]usize = undefined;

    switch (case) {
        .copy => |c| {
            const src = try mapBytes(c.size + c.src_off + 1);
            defer std.posix.munmap(src);
            const dst = try mapBytes(c.size + c.dst_off + 1);
            defer std.posix.munmap(dst);
            fillPattern(src, 0x5A);
            @memset(dst, 0xA5);

            for (cfg.impls[0..cfg.n_impls], 0..) |impl, j| {
                iters_state[j] = seedIterations(c.size);
                if (cfg.warmupNs() == 0) continue;
                iters_state[j] = switch (impl) {
                    inline else => |cp| blk: {
                        const m = measuredSample(runCopyFixed, .{
                            copyFnFor(cp), io, src, dst, c.size, c.src_off, c.dst_off,
                        }, iters_state[j], cfg.warmupNs());
                        checksum_out.* +%= m.result.checksum;
                        break :blk m.iters;
                    },
                };
            }
            for (0..cfg.samples) |s| {
                for (0..cfg.n_impls) |k| {
                    const j = (k + s) % cfg.n_impls;
                    const impl = cfg.impls[j];
                    const m = switch (impl) {
                        inline else => |cp| measuredSample(runCopyFixed, .{
                            copyFnFor(cp), io, src, dst, c.size, c.src_off, c.dst_off,
                        }, iters_state[j], cfg.sampleNs()),
                    };
                    iters_state[j] = m.iters;
                    checksum_out.* +%= m.result.checksum;
                    var size_buf: [24]u8 = undefined;
                    const size_json = std.fmt.bufPrint(
                        &size_buf,
                        "{d}",
                        .{c.size},
                    ) catch unreachable;
                    try emitSample(
                        w,
                        case,
                        size_json,
                        c.src_off,
                        c.dst_off,
                        null,
                        impl,
                        s,
                        m.result,
                    );
                }
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Case list construction
// ---------------------------------------------------------------------------

fn buildCases(arena: mem.Allocator, cfg: *const Config) ![]Case {
    var list: std.ArrayList(Case) = .empty;

    switch (cfg.suite) {
        .quick, .standard => {
            const sizes: []const usize = switch (cfg.suite) {
                .quick => &quick_sizes,
                else => &standard_sizes,
            };
            for (copy_profiles) |p| {
                for (sizes) |size| {
                    const id = try std.fmt.allocPrint(
                        arena,
                        "copy/{s}/{d}",
                        .{ p.name, size },
                    );
                    if (!cfg.matches(id)) continue;
                    try list.append(arena, .{ .copy = .{
                        .id = id,
                        .profile = p.name,
                        .size = size,
                        .src_off = p.src_off,
                        .dst_off = p.dst_off,
                    } });
                }
            }
        },
        .dist => {},
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    comptime {
        assert(math.isPowerOfTwo(chunk_bytes));
        assert(iterations_seed_min > 0);
        assert(iterations_hard_max >= iterations_seed_max);
    }

    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cfg = parseArgs(args);

    if (builtin.mode != .ReleaseFast) {
        std.debug.print(
            "bench-fastmem: warning: optimize={s}, benchmarks want ReleaseFast\n",
            .{@tagName(builtin.mode)},
        );
    }

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_file_writer.interface;

    const cases = try buildCases(arena, &cfg);
    std.debug.print("bench-fastmem: suite={s} cases={d} impls={d} samples={d}\n", .{
        @tagName(cfg.suite),
        cases.len,
        cfg.n_impls,
        cfg.samples,
    });

    try emitMeta(w, &cfg);

    if (cfg.list) {
        for (cases) |case| try emitCaseLine(w, case);
        try w.print("{{\"type\":\"end\",\"cases\":{d},\"elapsed_ns\":0}}\n", .{cases.len});
        try w.flush();
        return;
    }

    const start = Io.Timestamp.now(io, .awake);
    var checksum: u64 = 0;
    for (cases) |case| {
        std.debug.print("bench-fastmem: case {s}\n", .{case.id()});
        try runCase(&cfg, io, w, case, &checksum);
        try w.flush();
    }
    const elapsed_ns: u64 = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);

    mem.doNotOptimizeAway(checksum);

    try w.print("{{\"type\":\"end\",\"cases\":{d},\"elapsed_ns\":{d}}}\n", .{
        cases.len,
        elapsed_ns,
    });
    try w.flush();
    std.debug.print("bench-fastmem: done, {d} cases in {d:.1} s\n", .{
        cases.len,
        @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s,
    });
}
