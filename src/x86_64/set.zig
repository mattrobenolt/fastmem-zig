//! Byte fills with straight-line classes and model-specific large paths.
const ops = @import("ops.zig");
const tuning = @import("tuning.zig");
const t = tuning.selected;
const w = ops.width;
const V = ops.V;

inline fn pair(comptime width: u32, dst: [*]u8, value: u8, n: usize) void {
    const T = if (width < 16) @Int(.unsigned, width * 8) else @Vector(width, u8);
    const v: T = if (width < 16) (@as(T, @intCast(value)) * (~@as(T, 0) / 255)) else @splat(value);
    ops.store(T, dst, v);
    ops.store(T, dst + n - width, v);
}

pub inline fn small(
    comptime max: u32,
    comptime masked: bool,
    dst: [*]u8,
    value: u8,
    n: usize,
) bool {
    if (n > max) return false;
    if (n >= w) {
        const v: V = @splat(value);
        ops.store(V, dst, v);
        ops.store(V, dst + n - w, v);
        if (n > 2 * w) {
            ops.store(V, dst + w, v);
            ops.store(V, dst + n - 2 * w, v);
            if (n > 4 * w) {
                ops.store(V, dst + 2 * w, v);
                ops.store(V, dst + 3 * w, v);
                ops.store(V, dst + n - 3 * w, v);
                ops.store(V, dst + n - 4 * w, v);
            }
        }
    } else {
        if (comptime masked and tuning.small_masked_set and ops.mask_available and w == 64) {
            if (@intFromPtr(dst) & 0xfff <= 0xfc0) {
                ops.maskedSet(dst, value, n);
                return true;
            }
        }
        if (w == 64 and n >= 32) {
            pair(32, dst, value, n);
        } else if (n >= 16) {
            pair(16, dst, value, n);
        } else if (n >= 8) {
            pair(8, dst, value, n);
        } else if (n >= 4) {
            pair(4, dst, value, n);
        } else if (n >= 2) {
            pair(2, dst, value, n);
        } else if (n == 1) {
            dst[0] = value;
        }
    }
    return true;
}

pub inline fn set(dst: [*]u8, value: u8, n: usize) void {
    // The ladder also folds for constant-length slices, without a constant mask cost.
    if (!small(tuning.inline_max, false, dst, value, n)) _ = kernel(dst, value, n);
}

pub fn kernel(dst: ?*anyopaque, value: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n == 0) return dst;
    const d: [*]u8 = @ptrCast(dst.?);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    if (!small(8 * w, true, d, byte, n)) large(d, byte, n);
    return dst;
}

noinline fn large(dst: [*]u8, value: u8, n: usize) void {
    @disableIntrinsics();
    if (t.memset_nt_min) |threshold| {
        if (n >= threshold) return stream(dst, value, n);
    }
    if (t.rep_stosb_min) |threshold| {
        if (n > threshold) return ops.repSet(dst, value, n);
    }
    const v: V = @splat(value);
    ops.store(V, dst, v);
    ops.store(V, dst + w, v);
    ops.store(V, dst + 2 * w, v);
    ops.store(V, dst + 3 * w, v);
    var offset = 4 * w - (@intFromPtr(dst) & (w - 1));
    while (offset < n - 4 * w) : (offset += 4 * w) {
        ops.storeAligned(dst + offset, v);
        ops.storeAligned(dst + offset + w, v);
        ops.storeAligned(dst + offset + 2 * w, v);
        ops.storeAligned(dst + offset + 3 * w, v);
    }
    ops.store(V, dst + n - 4 * w, v);
    ops.store(V, dst + n - 3 * w, v);
    ops.store(V, dst + n - 2 * w, v);
    ops.store(V, dst + n - w, v);
}

fn stream(dst: [*]u8, value: u8, n: usize) void {
    @disableIntrinsics();
    const v: V = @splat(value);
    ops.store(V, dst, v);
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset <= n - 4 * w) : (offset += 4 * w) {
        ops.streamStore(dst + offset, v);
        ops.streamStore(dst + offset + w, v);
        ops.streamStore(dst + offset + 2 * w, v);
        ops.streamStore(dst + offset + 3 * w, v);
    }
    ops.fence();
    ops.store(V, dst + n - 4 * w, v);
    ops.store(V, dst + n - 3 * w, v);
    ops.store(V, dst + n - 2 * w, v);
    ops.store(V, dst + n - w, v);
}
