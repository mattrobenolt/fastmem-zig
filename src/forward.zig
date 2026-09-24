const std = @import("std");
const assert = std.debug.assert;

const common = @import("common.zig");

pub const Options = struct {
    tight_loop: bool = true,
    medium_straight_line: bool = false,
    align_to_source: bool = false,
    align_peel_min_bytes: usize = common.stride,
    software_pipeline_large_loop: bool = false,
    software_pipeline_large_loop_min_bytes: usize = common.stride * 16,
    large_copy_use_builtin: bool = false,
    large_copy_builtin_threshold: usize = 4096,
};

/// Forward loop for non-overlapping copies and overlap-safe forward moves.
pub inline fn run(
    comptime options: Options,
    comptime allow_builtin_fallback: bool,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    @disableIntrinsics();
    var d = dest;
    var s = src;
    var remaining = len;

    if (remaining < common.stride) return common.copySmall(d, s, remaining);

    // Keep the exact hot tiers out of the generic loop so the common
    // benchmarked sizes do not pay extra branch/update overhead.
    if (remaining == common.stride) {
        common.storeVN(common.vectors_per_stride, d, 0, common.loadVN(common.vectors_per_stride, s, 0));
        return;
    }
    // The 2-stride exact tier is a win on 16-byte-vector targets, but it
    // regresses the AVX2 256B misaligned and cross-lane copy cases.
    if (common.chunk_bytes == 16 and remaining == common.stride * 2) {
        const head = common.loadVN(common.vectors_per_stride, s, 0);
        const tail = common.loadVN(common.vectors_per_stride, s, remaining - common.stride);
        common.storeVN(common.vectors_per_stride, d, 0, head);
        common.storeVN(common.vectors_per_stride, d, remaining - common.stride, tail);
        return;
    }

    // On targets where LLVM generates a bloated loop body, bypass the
    // loop for medium sizes with straight-line loads then stores.
    // All loads complete before any stores — safe for overlapping regions.
    if (options.medium_straight_line) {
        if (remaining <= common.stride) {
            common.storeVN(common.vectors_per_stride, d, 0, common.loadVN(common.vectors_per_stride, s, 0));
            return;
        }
        if (remaining <= common.stride * 2) {
            const head = common.loadVN(common.vectors_per_stride, s, 0);
            const tail = common.loadVN(common.vectors_per_stride, s, remaining - common.stride);
            common.storeVN(common.vectors_per_stride, d, 0, head);
            common.storeVN(common.vectors_per_stride, d, remaining - common.stride, tail);
            return;
        }
    }

    // Align the hot loop only when enough work remains.
    if (remaining >= options.align_peel_min_bytes) {
        const mask = @as(usize, common.chunk_bytes - 1);
        const align_base = if (options.align_to_source) @intFromPtr(s) else @intFromPtr(d);
        const loop_misalignment = align_base & mask;
        if (loop_misalignment > 0) {
            const prefix = @as(usize, common.chunk_bytes) - loop_misalignment;
            common.copySmall(d, s, prefix);
            d += prefix;
            s += prefix;
            remaining -= prefix;
        }
    }

    if (remaining < common.stride) return common.copySmall(d, s, remaining);
    copyLargeForward(options, allow_builtin_fallback, d, s, remaining);
}

inline fn copyLargeForward(
    comptime options: Options,
    comptime allow_builtin_fallback: bool,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    @disableIntrinsics();
    assert(len >= common.stride);

    // Delegate to the platform's optimized implementation for large
    // non-overlapping copies. Only used from memcpy policy, not memmove.
    if (allow_builtin_fallback and options.large_copy_use_builtin and len >= options.large_copy_builtin_threshold) {
        @memcpy(dest[0..len], src[0..len]);
        return;
    }

    // On Neoverse-V2, a one-stride software pipeline matches glibc's
    // large aligned copy shape more closely than a simple load/store loop.
    if (options.software_pipeline_large_loop and
        common.chunk_bytes == 16 and
        len >= options.software_pipeline_large_loop_min_bytes)
    {
        const mask = @as(usize, common.chunk_bytes - 1);
        if (((@intFromPtr(dest) | @intFromPtr(src)) & mask) == 0) {
            copyLargeForwardPipelined(dest, src, len);
            return;
        }
    }

    if (options.tight_loop) {
        // Pointer bumping: known models produce tight codegen.
        var d = dest;
        var s = src;
        var remaining = len;
        while (remaining >= common.stride) {
            common.storeVN(common.vectors_per_stride, d, 0, common.loadVN(common.vectors_per_stride, s, 0));
            d += common.stride;
            s += common.stride;
            remaining -= common.stride;
        }
        if (remaining > 0) common.copySmall(d, s, remaining);
    } else {
        // Single offset: generic targets produce bloated codegen with
        // multiple induction variables; a single offset keeps the loop
        // body smaller.
        var off: usize = 0;
        while (off + common.stride <= len) : (off += common.stride) {
            common.storeVN(common.vectors_per_stride, dest + off, 0, common.loadVN(common.vectors_per_stride, src + off, 0));
        }
        const remaining = len - off;
        if (remaining > 0) common.copySmall(dest + off, src + off, remaining);
    }
}

noinline fn copyLargeForwardPipelined(dest: [*]u8, src: [*]const u8, len: usize) void {
    @disableIntrinsics();
    assert(common.chunk_bytes == 16);
    assert(len >= common.stride);

    var d = dest;
    var s = src;
    var remaining = len;

    var v0 = common.loadV(s);
    var v1 = common.loadV(s + common.chunk_bytes);
    var v2 = common.loadV(s + common.chunk_bytes * 2);
    var v3 = common.loadV(s + common.chunk_bytes * 3);
    s += common.stride;
    remaining -= common.stride;

    while (remaining >= common.stride) {
        const next0 = common.loadV(s);
        const next1 = common.loadV(s + common.chunk_bytes);
        const next2 = common.loadV(s + common.chunk_bytes * 2);
        const next3 = common.loadV(s + common.chunk_bytes * 3);
        common.storeV(d, v0);
        common.storeV(d + common.chunk_bytes, v1);
        common.storeV(d + common.chunk_bytes * 2, v2);
        common.storeV(d + common.chunk_bytes * 3, v3);
        v0 = next0;
        v1 = next1;
        v2 = next2;
        v3 = next3;
        d += common.stride;
        s += common.stride;
        remaining -= common.stride;
    }

    common.storeV(d, v0);
    common.storeV(d + common.chunk_bytes, v1);
    common.storeV(d + common.chunk_bytes * 2, v2);
    common.storeV(d + common.chunk_bytes * 3, v3);
    d += common.stride;

    if (remaining > 0) common.copySmall(d, s, remaining);
}
