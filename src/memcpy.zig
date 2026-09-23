const std = @import("std");
const assert = std.debug.assert;
const Target = std.Target;
const math = std.math;
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
    /// Min bytes before copy alignment peel, as stride multiples.
    copy_align_peel_min_strides: usize = 2,
    /// Fall back to @memcpy for large aligned copies (rep movsb on ERMS/FSRM x86).
    large_copy_use_builtin: bool = false,
    /// Threshold for large_copy_use_builtin (bytes).
    large_copy_builtin_threshold: usize = 4096,
    /// Use a software-pipelined large loop for aligned copies.
    software_pipeline_large_loop: bool = false,
    /// Threshold for software_pipeline_large_loop (bytes).
    software_pipeline_large_loop_threshold: usize = 1024,
    /// Fall back to libc-backed @memcpy for large copies when linked on GNU/Linux.
    large_copy_use_libc: bool = false,
    /// Threshold for large_copy_use_libc (bytes).
    large_copy_libc_threshold: usize = 4096,
};

pub const flags: Flags = switch (builtin.cpu.arch) {
    .aarch64 => if (builtin.cpu.model == &Target.aarch64.cpu.generic)
        .{
            .tight_loop = false,
            .medium_straight_line = true,
            .copy_align_peel_min_strides = 8,
        }
    else if (builtin.cpu.model == &Target.aarch64.cpu.apple_m1)
        .{
            .large_copy_use_builtin = true,
            .large_copy_builtin_threshold = 1024,
        }
    else if (builtin.cpu.model == &Target.aarch64.cpu.neoverse_v2)
        .{
            .align_forward_to_source = true,
            .software_pipeline_large_loop = true,
            .software_pipeline_large_loop_threshold = 1024,
            .large_copy_use_libc = true,
            .large_copy_libc_threshold = 1024,
        }
    else
        .{},
    .x86_64 => if (builtin.cpu.model == &Target.x86.cpu.x86_64)
        .{
            .tight_loop = false,
            .medium_straight_line = true,
            .copy_align_peel_min_strides = 8,
        }
    else if (builtin.cpu.model == &Target.x86.cpu.sapphirerapids)
        .{
            .large_copy_use_builtin = true,
            .large_copy_builtin_threshold = 2048,
        }
    else
        .{},
    else => .{},
};

pub const copy_align_peel_min = flags.copy_align_peel_min_strides * common.stride;

pub const forward_options: forward.Options = .{
    .tight_loop = flags.tight_loop,
    .medium_straight_line = flags.medium_straight_line,
    .align_to_source = flags.align_forward_to_source,
    .align_peel_min_bytes = copy_align_peel_min,
    .software_pipeline_large_loop = flags.software_pipeline_large_loop,
    .software_pipeline_large_loop_min_bytes = flags.software_pipeline_large_loop_threshold,
    .large_copy_use_builtin = flags.large_copy_use_builtin,
    .large_copy_builtin_threshold = flags.large_copy_builtin_threshold,
};

comptime {
    assert(copy_align_peel_min >= common.stride);
}

/// Non-overlapping copy. Prefer over @memcpy for runtime-sized copies
/// that may exceed ~32 bytes.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    assert(dest.len >= source.len);

    const byte_len = common.byteLen(T, source.len);
    if (byte_len == 0) return;

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);

    if (common.can_use_glibc_memops and flags.large_copy_use_libc and byte_len >= flags.large_copy_libc_threshold) {
        common.callLibcMemcpy(d, s, byte_len);
        return;
    }

    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    assert(s_addr <= math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;
    assert(d_addr <= s_addr or d_addr >= s_end);

    forward.run(forward_options, true, d, s, byte_len);
}
