//! Comptime tuning table for the aarch64 kernels: which small-size
//! (<= 64 byte) path the SVE kernels use, per CPU model.
//!
//! Variants for copy/move (the kernels share the small path, like AOR's
//! aliased memmove entry):
//! - sve:    the AOR memcpy-sve.S predicated pair for 0..2*VL
//!           (whilelo/ld1b/st1b; 0..64 on V1's 256-bit VL, 0..32 on
//!           V2/V3's 128-bit VL).
//! - neon:   the AOR memcpy-advsimd.S tbz tree for 0..15, one
//!           overlapping 16-byte pair for 16..32, then the unchanged
//!           mid block above 32. Fixed boundaries, no cntb/whilelo.
//! - hybrid: the tbz tree below 16, the SVE predicated pair for
//!           16..2*VL.
//!
//! For set:
//! - sve:    the AOR memset-sve.S predicated store below 16.
//! - neon:   the AOR memset-advsimd.S store tree below 16.
//!
//! The neon/hybrid tree blocks reuse the small-size classes of the
//! in-tree advsimd ports (same upstream files, same pinned commit, same
//! license); every access in them is sized to the count, so guard-page
//! tails stay safe.
//!
//! Evidence for the per-model defaults: docs/results/aor-g2-graviton.md
//! (run 20260924T064442Z-aor-g2). Below 16 bytes, compiler-rt's
//! scalar/NEON small path beats the SVE predicated pair on Neoverse V3
//! (fastmem_abi/builtin copy 1.50, move 1.40) and ties on V2
//! (copy 1.00, move 1.07), while the SVE pair wins on V1 (copy 0.87).
//! The fleet A/Bs variants as separate revisions that flip these
//! defaults; the -Dsmall-copy / -Dsmall-set build options override them
//! for local runs.

const builtin = @import("builtin");
const std = @import("std");
const options = @import("fastmem_options");

pub const CopySmall = enum { sve, neon, hybrid };
pub const SetSmall = enum { sve, neon };

const aarch64_cpu = std.Target.aarch64.cpu;

const default_copy_small: CopySmall = if (builtin.cpu.model == &aarch64_cpu.neoverse_v3)
    .neon
else
    .sve;

const default_set_small: SetSmall = if (builtin.cpu.model == &aarch64_cpu.neoverse_v3)
    .neon
else
    .sve;

pub const copy_small: CopySmall = blk: {
    if (std.mem.eql(u8, options.small_copy, "auto")) break :blk default_copy_small;
    break :blk std.meta.stringToEnum(CopySmall, options.small_copy) orelse
        @compileError("unknown -Dsmall-copy value: " ++ options.small_copy);
};

pub const set_small: SetSmall = blk: {
    if (std.mem.eql(u8, options.small_set, "auto")) break :blk default_set_small;
    break :blk std.meta.stringToEnum(SetSmall, options.small_set) orelse
        @compileError("unknown -Dsmall-set value: " ++ options.small_set);
};
