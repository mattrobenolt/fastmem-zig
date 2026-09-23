const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Target = std.Target;
const builtin = @import("builtin");

const common = @import("common.zig");
const forward = @import("forward.zig");

pub const Flags = struct {
    /// Pointer-bumping loop (tight codegen) vs single-offset loop.
    tight_loop: bool = true,
    /// Straight-line medium tiers (stride, stride*2) before entering the loop.
    medium_straight_line: bool = false,
    /// Align the forward loop to source loads instead of destination stores.
    align_forward_to_source: bool = false,
    /// Align the backward loop to source-end loads instead of destination-end stores.
    align_backward_to_source_end: bool = false,
    /// Forward-move peel floor in bytes (actual min = max(stride*2, this)).
    move_fwd_peel_min_bytes: usize = 2048,
    /// Backward-move peel in stride multiples.
    move_bwd_peel_min_strides: usize = 2,
    /// Fall back to libc-backed @memmove for large moves on GNU/Linux.
    large_move_use_libc: bool = false,
    /// Threshold for large_move_use_libc (bytes).
    large_move_libc_threshold: usize = 4096,
    /// Fall back to libc-backed @memmove for backward-overlap moves on GNU/Linux.
    large_backward_move_use_libc: bool = false,
    /// Threshold for large_backward_move_use_libc (bytes).
    large_backward_move_libc_threshold: usize = 4096,
};

pub const flags: Flags = switch (builtin.cpu.arch) {
    .aarch64 => if (builtin.cpu.model == &Target.aarch64.cpu.generic)
        .{
            .tight_loop = false,
            .medium_straight_line = true,
        }
    else if (builtin.cpu.model == &Target.aarch64.cpu.neoverse_v2)
        .{
            .align_forward_to_source = true,
            .align_backward_to_source_end = true,
            .move_fwd_peel_min_bytes = 128,
            .large_move_use_libc = true,
            .large_move_libc_threshold = 1024,
            .large_backward_move_use_libc = true,
            .large_backward_move_libc_threshold = 256,
        }
    else
        .{},
    .x86_64 => if (builtin.cpu.model == &Target.x86.cpu.x86_64)
        .{
            .tight_loop = false,
            .medium_straight_line = true,
        }
    else
        .{},
    else => .{},
};

pub const move_forward_align_peel_min: usize = @max(common.stride * 2, flags.move_fwd_peel_min_bytes);
pub const move_backward_align_peel_min = flags.move_bwd_peel_min_strides * common.stride;

const forward_options: forward.Options = .{
    .tight_loop = flags.tight_loop,
    .medium_straight_line = flags.medium_straight_line,
    .align_to_source = flags.align_forward_to_source,
    .align_peel_min_bytes = move_forward_align_peel_min,
};

comptime {
    assert(move_forward_align_peel_min >= common.stride);
    assert(move_backward_align_peel_min >= common.stride);
}

/// Overlapping-safe move. Prefer over @memmove for runtime-sized moves.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);

    const byte_len = common.byteLen(T, source.len);
    if (byte_len == 0) return;

    if (common.can_use_glibc_memops and flags.large_move_use_libc and byte_len >= flags.large_move_libc_threshold) {
        common.callLibcMemmove(@ptrCast(dest.ptr), @ptrCast(source.ptr), byte_len);
        return;
    }

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);
    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    // On Neoverse-V2, the libc memmove path wins for dest > src once we get
    // beyond the tiny copySmall tier. Call libc directly so LLVM does not
    // silently inline a different memmove sequence for the floor path.
    if (common.can_use_glibc_memops and flags.large_backward_move_use_libc and byte_len >= flags.large_backward_move_libc_threshold and d_addr > s_addr) {
        common.callLibcMemmove(d, s, byte_len);
        return;
    }

    assert(s_addr <= math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;

    // Forward is safe when dest <= src or regions don't overlap.
    if (d_addr <= s_addr) {
        return forward.run(forward_options, false, d, s, byte_len);
    }
    if (d_addr >= s_end) {
        return forward.run(forward_options, false, d, s, byte_len);
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
        const end_base = if (flags.align_backward_to_source_end) @intFromPtr(s) else @intFromPtr(d);
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
