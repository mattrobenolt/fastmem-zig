//! Independent implementation of the behavioral design in x86_64-design.md.
const builtin = @import("builtin");
const ops = @import("ops.zig");
const tuning = @import("tuning.zig");
const t = tuning.selected;
const w = ops.width;
const V = ops.vector;
pub const Overlap = enum { may_overlap, disjoint };

inline fn pair(comptime T: type, dst: [*]u8, src: [*]const u8, n: usize) void {
    const a = ops.load(T, src);
    const b = ops.load(T, src + n - @sizeOf(T));
    ops.store(T, dst, a);
    ops.store(T, dst + n - @sizeOf(T), b);
}

pub inline fn small(comptime max: u32, dst: [*]u8, src: [*]const u8, n: usize) bool {
    if (n > max) return false;
    if (n >= w) {
        if (n <= 2 * w) {
            pair(V, dst, src, n);
        } else if (n <= 4 * w) {
            const a = ops.load(V, src);
            const b = ops.load(V, src + w);
            const c = ops.load(V, src + n - 2 * w);
            const d = ops.load(V, src + n - w);
            ops.store(V, dst, a);
            ops.store(V, dst + w, b);
            ops.store(V, dst + n - 2 * w, c);
            ops.store(V, dst + n - w, d);
        } else {
            const a = ops.load(V, src);
            const b = ops.load(V, src + w);
            const c = ops.load(V, src + 2 * w);
            const d = ops.load(V, src + 3 * w);
            const e = ops.load(V, src + n - 4 * w);
            const f = ops.load(V, src + n - 3 * w);
            const g = ops.load(V, src + n - 2 * w);
            const h = ops.load(V, src + n - w);
            ops.store(V, dst, a);
            ops.store(V, dst + w, b);
            ops.store(V, dst + 2 * w, c);
            ops.store(V, dst + 3 * w, d);
            ops.store(V, dst + n - 4 * w, e);
            ops.store(V, dst + n - 3 * w, f);
            ops.store(V, dst + n - 2 * w, g);
            ops.store(V, dst + n - w, h);
        }
    } else if (w == 64 and n >= 32) {
        pair(@Vector(32, u8), dst, src, n);
    } else if (n >= 16) {
        pair(@Vector(16, u8), dst, src, n);
    } else if (n >= 8) {
        pair(u64, dst, src, n);
    } else if (n >= 4) {
        pair(u32, dst, src, n);
    } else if (n >= 2) {
        pair(u16, dst, src, n);
    } else if (n == 1) {
        dst[0] = src[0];
    }
    return true;
}

pub inline fn move(comptime overlap: Overlap, dst: [*]u8, src: [*]const u8, n: usize) void {
    if (small(tuning.inline_max, dst, src, n)) return;
    if (overlap == .disjoint) {
        // The disjoint specialization omits the direction test, but retains alias dispatch.
        copyLarge(dst, src, n);
    } else {
        _ = kernel(dst, src, n);
    }
}

pub noinline fn kernel(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n <= 16) {
        if (n == 0) return dst;
        const d: [*]u8 = @ptrCast(dst.?);
        const s: [*]const u8 = @ptrCast(src.?);
        if (n >= 8) {
            pair(u64, d, s, n);
        } else if (n >= 4) {
            pair(u32, d, s, n);
        } else if (n >= 2) {
            pair(u16, d, s, n);
        } else {
            d[0] = s[0];
        }
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n <= 32) {
        pair(@Vector(16, u8), d, s, n);
        return dst;
    }
    return @call(if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto, mediumKernel, .{ dst, src, n });
}

noinline fn mediumKernel(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (!small(8 * w, d, s, n)) return @call(if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto, largeKernel, .{ dst, src, n });
    return dst;
}

// The matching return convention permits a tail transfer from the leaf entry.
noinline fn largeKernel(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    large(.may_overlap, @ptrCast(dst.?), @ptrCast(src.?), n);
    return dst;
}

noinline fn copyLarge(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    if (!small(8 * w, dst, src, n)) large(.disjoint, dst, src, n);
}

fn large(comptime overlap: Overlap, dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const distance = @intFromPtr(dst) -% @intFromPtr(src);
    if (overlap == .may_overlap) {
        if (distance == 0) return;
        if (distance < n) return backward(dst, src, n);
    }
    const source_inside = overlap == .may_overlap and @intFromPtr(src) -% @intFromPtr(dst) < n;
    if (t.rep_movsb_min) |threshold| {
        // The gap override permits H8 without the short-distance REP penalty.
        const rep_overlap = if (t.rep_fwd_gap_min) |gap|
            @intFromPtr(src) -% @intFromPtr(dst) >= gap
        else
            false;
        if ((!source_inside or rep_overlap) and n > threshold and (t.nt_min == null or n < t.nt_min.?)) {
            const head = ops.load(V, src);
            const address = if (distance & t.rep_src_align_mask == 0)
                @intFromPtr(src)
            else
                @intFromPtr(dst);
            const skip = w - (address & (w - 1));
            ops.repMove(dst + skip, src + skip, n - skip);
            ops.store(V, dst, head);
            return;
        }
    }
    if (t.nt_min) |threshold| {
        if (!source_inside and n >= threshold) return stream(dst, src, n);
    }
    // A source inside the destination requires forward traversal, even with a 4K alias.
    if (!source_inside and distance & t.alias_mask == 0) return backward(dst, src, n);
    forward(dst, src, n);
}

fn forward(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const head = ops.load(V, src);
    const a = ops.load(V, src + n - 4 * w);
    const b = ops.load(V, src + n - 3 * w);
    const c = ops.load(V, src + n - 2 * w);
    const d = ops.load(V, src + n - w);
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset < n - 4 * w) : (offset += 4 * w) {
        const e = ops.load(V, src + offset);
        const f = ops.load(V, src + offset + w);
        const g = ops.load(V, src + offset + 2 * w);
        const h = ops.load(V, src + offset + 3 * w);
        ops.storeAligned(dst + offset, e);
        ops.storeAligned(dst + offset + w, f);
        ops.storeAligned(dst + offset + 2 * w, g);
        ops.storeAligned(dst + offset + 3 * w, h);
    }
    ops.store(V, dst + n - 4 * w, a);
    ops.store(V, dst + n - 3 * w, b);
    ops.store(V, dst + n - 2 * w, c);
    ops.store(V, dst + n - w, d);
    ops.store(V, dst, head);
}

fn backward(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const a = ops.load(V, src);
    const b = ops.load(V, src + w);
    const c = ops.load(V, src + 2 * w);
    const d = ops.load(V, src + 3 * w);
    const tail = ops.load(V, src + n - w);
    var end = n - ((@intFromPtr(dst) + n) & (w - 1));
    while (end > 4 * w) {
        end -= 4 * w;
        const e = ops.load(V, src + end);
        const f = ops.load(V, src + end + w);
        const g = ops.load(V, src + end + 2 * w);
        const h = ops.load(V, src + end + 3 * w);
        ops.storeAligned(dst + end, e);
        ops.storeAligned(dst + end + w, f);
        ops.storeAligned(dst + end + 2 * w, g);
        ops.storeAligned(dst + end + 3 * w, h);
    }
    ops.store(V, dst, a);
    ops.store(V, dst + w, b);
    ops.store(V, dst + 2 * w, c);
    ops.store(V, dst + 3 * w, d);
    ops.store(V, dst + n - w, tail);
}

fn stream(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    ops.store(V, dst, ops.load(V, src));
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset <= n - 4 * w) : (offset += 4 * w) {
        if (offset + 8 * w < n) @prefetch(src + offset + 8 * w, .{ .rw = .read, .locality = 3 });
        const a = ops.load(V, src + offset);
        const b = ops.load(V, src + offset + w);
        const c = ops.load(V, src + offset + 2 * w);
        const d = ops.load(V, src + offset + 3 * w);
        ops.streamStore(dst + offset, a);
        ops.streamStore(dst + offset + w, b);
        ops.streamStore(dst + offset + 2 * w, c);
        ops.streamStore(dst + offset + 3 * w, d);
    }
    ops.fence();
    _ = small(8 * w, dst + n - 4 * w, src + n - 4 * w, 4 * w);
}
