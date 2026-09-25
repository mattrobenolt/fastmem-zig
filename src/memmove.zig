const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const common = @import("common.zig");
const forward = @import("forward.zig");

/// Tuning of the generic Zig fallback (see memcpy.zig). The fallback never
/// calls memcpy, memmove, or memset through a symbol.
const Flags = struct {
    tight_loop: bool,
    medium_straight_line: bool,
    move_fwd_peel_min_bytes: usize,
    move_bwd_peel_min_strides: usize,
};

const flags: Flags = .{
    .tight_loop = false,
    .medium_straight_line = true,
    .move_fwd_peel_min_bytes = 2048,
    .move_bwd_peel_min_strides = 2,
};

pub const move_forward_align_peel_min: usize = @max(common.stride * 2, flags.move_fwd_peel_min_bytes);
pub const move_backward_align_peel_min = flags.move_bwd_peel_min_strides * common.stride;

const forward_options: forward.Options = .{
    .tight_loop = flags.tight_loop,
    .medium_straight_line = flags.medium_straight_line,
    .align_peel_min_bytes = move_forward_align_peel_min,
};

comptime {
    assert(move_forward_align_peel_min >= common.stride);
    assert(move_backward_align_peel_min >= common.stride);
}

/// Overlapping-safe move. Prefer over @memmove for runtime-sized moves.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    @disableIntrinsics();
    assert(dest.len >= source.len);

    const byte_len = common.byteLen(T, source.len);
    if (byte_len == 0) return;

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);
    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    // On Neoverse-V2, the libc memmove path wins for dest > src once we get
    // beyond the tiny copySmall tier. Call libc directly so LLVM does not
    // silently inline a different memmove sequence for the floor path.
    assert(s_addr <= math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;

    // Forward is safe when dest <= src or regions don't overlap.
    if (d_addr <= s_addr) {
        return forward.run(forward_options, d, s, byte_len);
    }
    if (d_addr >= s_end) {
        return forward.run(forward_options, d, s, byte_len);
    }

    // Overlapping with dest > src.
    // Small path loads all data before any stores — inherently safe.
    if (byte_len < common.stride) return common.copySmall(d, s, byte_len);

    var remaining = byte_len;

    // Peel an unaligned tail only when enough work remains to amortize it.
    // On Neoverse-V2, glibc aligns the source end so the hot loop gets
    // aligned loads even when the destination remains misaligned.
    if (remaining >= move_backward_align_peel_min) {
        const mask = @as(usize, common.chunk_bytes - 1);
        const end_base = @intFromPtr(d);
        const end_misalignment = (end_base + remaining) & mask;
        if (end_misalignment > 0) {
            common.copySmall(d + remaining - end_misalignment, s + remaining - end_misalignment, end_misalignment);
            remaining -= end_misalignment;
        }
    }

    if (remaining < common.stride) return common.copySmall(d, s, remaining);
    copyLargeBackward(d, s, remaining);
}

/// Backward loop for >= stride bytes with overlapping dest > src.
/// Finishes with copySmall for the remaining prefix.
inline fn copyLargeBackward(dest: [*]u8, src: [*]const u8, len: usize) void {
    @disableIntrinsics();
    assert(len >= common.stride);

    if (flags.tight_loop) {
        var d = dest + len;
        var s = src + len;
        var remaining = len;
        while (remaining >= common.stride) {
            d -= common.stride;
            s -= common.stride;
            common.storeVN(common.vectors_per_stride, d, 0, common.loadVN(common.vectors_per_stride, s, 0));
            remaining -= common.stride;
        }
        if (remaining > 0) common.copySmall(dest, src, remaining);
    } else {
        var off = len;
        while (off >= common.stride) {
            off -= common.stride;
            common.storeVN(common.vectors_per_stride, dest + off, 0, common.loadVN(common.vectors_per_stride, src + off, 0));
        }
        if (off > 0) common.copySmall(dest, src, off);
    }
}
