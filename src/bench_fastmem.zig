//! Microbenchmarks for src/fastmem.zig against Zig builtins.
//!
//! This is intentionally a simple in-repo harness:
//! - Compares `fastmem.copy` vs `@memcpy` for non-overlapping copies.
//! - Compares `fastmem.move` vs `@memmove` for overlapping moves.
//! - Sweeps representative sizes, alignments, and overlap directions.
//! - Uses duration-based sampling with warmup and percentile reporting.
//! - Emits Go-style benchmark lines (`Benchmark... N ns/op MB/s`) for
//!   compatibility with tools like `benchstat`.

const std = @import("std");
const Timer = std.time.Timer;
const assert = std.debug.assert;
const print = std.debug.print;
const doNotOptimizeAway = std.mem.doNotOptimizeAway;
const builtin = @import("builtin");

const bench_options = @import("bench_options");
const has_libc = bench_options.link_libc;
const fastmem = @import("fastmem");

const sample_count = 9;
const warmup_target_ns: u64 = 20 * std.time.ns_per_ms;
const sample_target_ns: u64 = 60 * std.time.ns_per_ms;
const seed_target_bytes_per_case = 32 * 1024 * 1024;
const iterations_seed_min = 256;
const iterations_seed_max = 4_000_000;
const iterations_hard_max = 64 * 1024 * 1024;
const max_size = 16 * 1024;
const max_offset = 64;

const chunk_bytes = @min(std.simd.suggestVectorLength(u8) orelse 16, 32);
extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

const sizes = [_]usize{ 64, 256, 1024, 4096, 16384 };

const CopyProfile = struct {
    name: []const u8,
    source_offset: usize,
    dest_offset: usize,
};

const copy_profiles = [_]CopyProfile{
    .{ .name = "aligned", .source_offset = 0, .dest_offset = 0 },
    .{ .name = "misaligned", .source_offset = 1, .dest_offset = 3 },
    .{
        .name = "cross-lane",
        .source_offset = chunk_bytes - 1,
        .dest_offset = chunk_bytes / 2,
    },
};

const move_gaps = [_]usize{
    1,
    chunk_bytes - 1,
    chunk_bytes + 1,
};

const MoveDirection = enum {
    forward_overlap,
    backward_overlap,
};

const Stats = struct {
    elapsed_ns: u64,
    iterations: usize,
    bytes_per_iteration: usize,
    checksum: u64,

    fn nsPerOp(self: Stats) f64 {
        assert(self.iterations > 0);
        return @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(self.iterations));
    }

    fn gibPerSecond(self: Stats) f64 {
        assert(self.iterations > 0);
        assert(self.bytes_per_iteration > 0);

        const elapsed_ns = @max(self.elapsed_ns, 1);
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const total_bytes = self.bytes_per_iteration * self.iterations;
        return @as(f64, @floatFromInt(total_bytes)) / elapsed_seconds / (1024.0 * 1024.0 * 1024.0);
    }

    fn mbPerSecond(self: Stats) f64 {
        assert(self.iterations > 0);
        assert(self.bytes_per_iteration > 0);

        const elapsed_ns = @max(self.elapsed_ns, 1);
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const total_bytes = self.bytes_per_iteration * self.iterations;
        return @as(f64, @floatFromInt(total_bytes)) / elapsed_seconds / 1_000_000.0;
    }
};

const Summary = struct {
    sample_count: usize,
    iterations_p50: usize,
    bytes_per_iteration: usize,
    checksum: u64,
    samples: [sample_count]Stats,
    ns_per_op_min: f64,
    ns_per_op_p50: f64,
    ns_per_op_p95: f64,
    ns_per_op_max: f64,
    gib_per_second_min: f64,
    gib_per_second_p50: f64,
    gib_per_second_p95: f64,
    gib_per_second_max: f64,

    fn mbPerSecondP50(self: Summary) f64 {
        assert(self.ns_per_op_p50 > 0);
        const elapsed_seconds = self.ns_per_op_p50 / 1_000_000_000.0;
        const bytes = @as(f64, @floatFromInt(self.bytes_per_iteration));
        return bytes / elapsed_seconds / 1_000_000.0;
    }
};

const Impl = enum {
    builtin,
    fastmem,
    libc,
};

fn copyBuiltin(dest: []u8, source: []const u8) void {
    @memcpy(dest, source);
}

fn copyFast(dest: []u8, source: []const u8) void {
    fastmem.copy(u8, dest, source);
}

fn moveBuiltin(dest: []u8, source: []const u8) void {
    @memmove(dest, source);
}

fn moveFast(dest: []u8, source: []const u8) void {
    fastmem.move(u8, dest, source);
}

fn copyLibc(dest: []u8, source: []const u8) void {
    _ = memcpy(@ptrCast(dest.ptr), @ptrCast(source.ptr), source.len);
}

fn moveLibc(dest: []u8, source: []const u8) void {
    _ = memmove(@ptrCast(dest.ptr), @ptrCast(source.ptr), source.len);
}

fn fillPattern(buffer: []u8, seed: u8) void {
    for (buffer, 0..) |*b, i| {
        b.* = @truncate(i * 131 + seed);
    }
}

fn chooseInitialIterations(size: usize) usize {
    assert(size > 0);

    const target_iterations = seed_target_bytes_per_case / size;
    return std.math.clamp(target_iterations, iterations_seed_min, iterations_seed_max);
}

fn runCopyOnce(
    comptime op: fn (dest: []u8, source: []const u8) void,
    size: usize,
    source_offset: usize,
    dest_offset: usize,
    iterations: usize,
    sample_seed: u8,
) !Stats {
    assert(size > 0);
    assert(size <= max_size);
    assert(source_offset < max_offset);
    assert(dest_offset < max_offset);
    assert(iterations > 0);

    var source_storage: [max_size + max_offset]u8 align(64) = undefined;
    var dest_storage: [max_size + max_offset]u8 align(64) = undefined;

    fillPattern(&source_storage, sample_seed);
    @memset(&dest_storage, 0xA5);

    var source_mut = source_storage[source_offset..][0..size];
    const source_const: []const u8 = source_mut;
    const dest = dest_storage[dest_offset..][0..size];

    var checksum: u64 = 0;
    const index_mask = size - 1;

    var timer = try Timer.start();
    for (0..iterations) |i| {
        const index = (i * 13) & index_mask;
        op(dest, source_const);
        checksum +%= dest[index];
        source_mut[index] +%= @truncate(i + 1);
    }
    const elapsed_ns = timer.read();

    doNotOptimizeAway(source_storage);
    doNotOptimizeAway(dest_storage);
    doNotOptimizeAway(checksum);

    return .{
        .elapsed_ns = elapsed_ns,
        .iterations = iterations,
        .bytes_per_iteration = size,
        .checksum = checksum,
    };
}

fn runMoveOnce(
    comptime op: fn (dest: []u8, source: []const u8) void,
    size: usize,
    gap: usize,
    direction: MoveDirection,
    iterations: usize,
    sample_seed: u8,
) !Stats {
    assert(size > 0);
    assert(size <= max_size);
    assert(gap > 0);
    assert(gap < max_offset);
    assert(iterations > 0);

    var storage: [max_size + max_offset]u8 align(64) = undefined;
    fillPattern(&storage, sample_seed);

    var source_mut: []u8 = undefined;
    var dest: []u8 = undefined;
    switch (direction) {
        .forward_overlap => {
            assert(size + gap <= storage.len);
            source_mut = storage[gap..][0..size];
            dest = storage[0..size];
        },
        .backward_overlap => {
            assert(size + gap <= storage.len);
            source_mut = storage[0..size];
            dest = storage[gap..][0..size];
        },
    }
    const source_const: []const u8 = source_mut;

    var checksum: u64 = 0;
    const index_mask = size - 1;

    var timer = try Timer.start();
    for (0..iterations) |i| {
        const index = (i * 29) & index_mask;
        op(dest, source_const);
        checksum +%= dest[index];
        source_mut[index] +%= @truncate(i + 3);
    }
    const elapsed_ns = timer.read();

    doNotOptimizeAway(storage);
    doNotOptimizeAway(checksum);

    return .{
        .elapsed_ns = elapsed_ns,
        .iterations = iterations,
        .bytes_per_iteration = size,
        .checksum = checksum,
    };
}

fn sortF64(values: []f64) void {
    if (values.len <= 1) return;

    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn sortUsize(values: []usize) void {
    if (values.len <= 1) return;

    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn percentileIndex(count: usize, numerator: usize, denominator: usize) usize {
    assert(count > 0);
    assert(numerator > 0 and numerator <= denominator);
    const rank = (count * numerator + denominator - 1) / denominator;
    return @min(rank - 1, count - 1);
}

fn scaleIterations(iterations: usize, elapsed_ns: u64, target_ns: u64) usize {
    assert(iterations > 0);
    if (iterations >= iterations_hard_max) return iterations_hard_max;

    const doubled = if (iterations > iterations_hard_max / 2) iterations_hard_max else iterations * 2;
    if (elapsed_ns == 0) return doubled;

    // Add a bit of headroom so the next sample typically clears target_ns.
    const target_with_headroom = target_ns + target_ns / 5;
    const scaled_u128 = (@as(u128, iterations) * @as(u128, target_with_headroom) + @as(u128, elapsed_ns) - 1) / @as(u128, elapsed_ns);
    var scaled: usize = if (scaled_u128 > iterations_hard_max) iterations_hard_max else @intCast(scaled_u128);

    if (scaled <= iterations) scaled = doubled;
    if (scaled > iterations_hard_max) scaled = iterations_hard_max;
    return scaled;
}

fn runTimedSample(
    comptime run_fn: anytype,
    args: anytype,
    initial_iterations: usize,
    sample_seed: u8,
    min_elapsed_ns: u64,
) !Stats {
    var iterations = initial_iterations;
    while (true) {
        const s = try @call(.auto, run_fn, args ++ .{ iterations, sample_seed });
        if (s.elapsed_ns >= min_elapsed_ns or iterations >= iterations_hard_max) return s;
        iterations = scaleIterations(iterations, s.elapsed_ns, min_elapsed_ns);
    }
}

fn benchmarkOnce(
    comptime run_fn: anytype,
    args: anytype,
    initial_iterations: usize,
) !Summary {
    var sample_stats: [sample_count]Stats = undefined;
    var ns_samples: [sample_count]f64 = undefined;
    var gibs_samples: [sample_count]f64 = undefined;
    var iterations_samples: [sample_count]usize = undefined;
    var checksum: u64 = 0;

    var warmup_iterations = @max(initial_iterations / 4, iterations_seed_min);
    const warmup = try runTimedSample(run_fn, args, warmup_iterations, 0xFF, warmup_target_ns);
    checksum +%= warmup.checksum;
    warmup_iterations = warmup.iterations;

    var sample_iterations = @max(initial_iterations, warmup_iterations);
    for (0..sample_count) |sample| {
        const seed: u8 = @truncate(31 * sample + 7);
        const s = try runTimedSample(run_fn, args, sample_iterations, seed, sample_target_ns);
        sample_iterations = s.iterations;

        sample_stats[sample] = s;
        ns_samples[sample] = s.nsPerOp();
        gibs_samples[sample] = s.gibPerSecond();
        iterations_samples[sample] = s.iterations;
        checksum +%= s.checksum;
    }

    var ns_sorted = ns_samples;
    var gibs_sorted = gibs_samples;
    var iterations_sorted = iterations_samples;
    sortF64(ns_sorted[0..]);
    sortF64(gibs_sorted[0..]);
    sortUsize(iterations_sorted[0..]);

    const p50_index = percentileIndex(sample_count, 50, 100);
    const p95_index = percentileIndex(sample_count, 95, 100);

    return .{
        .sample_count = sample_count,
        .iterations_p50 = iterations_sorted[p50_index],
        .bytes_per_iteration = args[1], // size is always second arg
        .checksum = checksum,
        .samples = sample_stats,
        .ns_per_op_min = ns_sorted[0],
        .ns_per_op_p50 = ns_sorted[p50_index],
        .ns_per_op_p95 = ns_sorted[p95_index],
        .ns_per_op_max = ns_sorted[sample_count - 1],
        .gib_per_second_min = gibs_sorted[0],
        .gib_per_second_p50 = gibs_sorted[p50_index],
        .gib_per_second_p95 = gibs_sorted[p95_index],
        .gib_per_second_max = gibs_sorted[sample_count - 1],
    };
}

fn printBenchLine(name: []const u8, impl: Impl, stats: Summary, baseline: ?Summary) void {
    const impl_name = switch (impl) {
        .builtin => "builtin",
        .fastmem => "fastmem",
        .libc => "libc",
    };

    var full_name_buf: [96]u8 = undefined;
    const full_name = std.fmt.bufPrint(&full_name_buf, "Benchmark{s}/impl={s}", .{
        name,
        impl_name,
    }) catch unreachable;
    for (stats.samples) |sample| {
        print("{s}\t{d}\t{d:.4} ns/op\t{d:.2} MB/s\n", .{
            full_name,
            sample.iterations,
            sample.nsPerOp(),
            sample.mbPerSecond(),
        });
    }

    var stat_name_buf: [96]u8 = undefined;
    const stat_name = std.fmt.bufPrint(&stat_name_buf, "BenchStat{s}/impl={s}", .{
        name,
        impl_name,
    }) catch unreachable;
    print("{s}\tsamples={d}\tns/op p50={d:.2} p95={d:.2}\tGiB/s p50={d:.2} p95={d:.2}", .{
        stat_name,
        stats.sample_count,
        stats.ns_per_op_p50,
        stats.ns_per_op_p95,
        stats.gib_per_second_p50,
        stats.gib_per_second_p95,
    });

    if (baseline) |base| {
        const base_gibs = base.gib_per_second_p50;
        if (base_gibs > 0) {
            const pct = (stats.gib_per_second_p50 - base_gibs) / base_gibs * 100.0;
            const sign: u8 = if (pct >= 0) '+' else '-';
            print("\tdelta_vs_builtin_p50={c}{d:.1}%", .{ sign, @abs(pct) });
        }
    }
    print("\n", .{});
}

fn directionName(direction: MoveDirection) []const u8 {
    return switch (direction) {
        .forward_overlap => "fwd",
        .backward_overlap => "bwd",
    };
}

fn benchCopySuite() !u64 {
    var checksum: u64 = 0;
    for (copy_profiles) |profile| {
        for (sizes) |size| {
            const iterations = chooseInitialIterations(size);
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Copy/profile={s}/size={d}B", .{ profile.name, size }) catch unreachable;

            const baseline = try benchmarkOnce(runCopyOnce, .{ copyBuiltin, size, profile.source_offset, profile.dest_offset }, iterations);
            printBenchLine(name, .builtin, baseline, null);
            checksum +%= baseline.checksum;

            const fast = try benchmarkOnce(runCopyOnce, .{ copyFast, size, profile.source_offset, profile.dest_offset }, iterations);
            printBenchLine(name, .fastmem, fast, baseline);
            checksum +%= fast.checksum;

            if (has_libc) {
                const libc = try benchmarkOnce(runCopyOnce, .{ copyLibc, size, profile.source_offset, profile.dest_offset }, iterations);
                printBenchLine(name, .libc, libc, baseline);
                checksum +%= libc.checksum;
            }
        }
    }
    return checksum;
}

fn benchMoveSuite() !u64 {
    var checksum: u64 = 0;
    for ([_]MoveDirection{ .forward_overlap, .backward_overlap }) |direction| {
        for (move_gaps) |gap| {
            for (sizes) |size| {
                const iterations = chooseInitialIterations(size);
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "Move/dir={s}/gap={d}/size={d}B", .{
                    directionName(direction), gap, size,
                }) catch unreachable;

                const baseline = try benchmarkOnce(runMoveOnce, .{ moveBuiltin, size, gap, direction }, iterations);
                printBenchLine(name, .builtin, baseline, null);
                checksum +%= baseline.checksum;

                const fast = try benchmarkOnce(runMoveOnce, .{ moveFast, size, gap, direction }, iterations);
                printBenchLine(name, .fastmem, fast, baseline);
                checksum +%= fast.checksum;

                if (has_libc) {
                    const libc = try benchmarkOnce(runMoveOnce, .{ moveLibc, size, gap, direction }, iterations);
                    printBenchLine(name, .libc, libc, baseline);
                    checksum +%= libc.checksum;
                }
            }
        }
    }
    return checksum;
}

fn printFlags() void {
    const f = fastmem.flags;
    print("Flags: tight_loop={} medium_straight_line={}" ++
        " copy_align_peel_min_strides={d}" ++
        " move_fwd_peel_min_bytes={d}" ++
        " move_bwd_peel_min_strides={d}" ++
        " large_copy_use_builtin={}" ++
        " large_copy_builtin_threshold={d}\n", .{
        f.tight_loop,
        f.medium_straight_line,
        f.copy_align_peel_min_strides,
        f.move_fwd_peel_min_bytes,
        f.move_bwd_peel_min_strides,
        f.large_copy_use_builtin,
        f.large_copy_builtin_threshold,
    });
}

pub fn main() !void {
    comptime {
        assert(sample_count > 0);
        assert(iterations_seed_min > 0);
        assert(iterations_seed_max >= iterations_seed_min);
        assert(iterations_hard_max >= iterations_seed_max);
        assert(sample_target_ns > 0);
        assert(std.math.isPowerOfTwo(chunk_bytes));
        assert(copy_profiles.len > 0);
        assert(move_gaps.len > 0);
    }

    if (builtin.mode != .ReleaseFast) {
        print(
            "warning: benchmark is most meaningful in ReleaseFast mode (current={s})\n",
            .{@tagName(builtin.mode)},
        );
    }

    print("os.tag: {s}\n", .{@tagName(builtin.target.os.tag)});
    print("cpu.arch: {s}\n", .{@tagName(builtin.target.cpu.arch)});
    print("cpu.model: {s}\n", .{builtin.target.cpu.model.name});
    print("BenchmarkConfig: samples={d} warmup_ms={d} sample_ms={d} chunk_bytes={d} libc={}\n", .{
        sample_count,
        warmup_target_ns / std.time.ns_per_ms,
        sample_target_ns / std.time.ns_per_ms,
        chunk_bytes,
        has_libc,
    });
    printFlags();
    print("\n", .{});

    var checksum_total: u64 = 0;
    checksum_total +%= try benchCopySuite();
    checksum_total +%= try benchMoveSuite();

    doNotOptimizeAway(checksum_total);
    print("PASS\n", .{});
}
