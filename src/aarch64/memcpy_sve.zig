// memcpy - copy memory area
//
// Copyright (c) 2019-2023, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memcpy-sve.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534 (includes 23c4393006122497,
// "Improve __memcpy_aarch64_sve": the cntb hoist and .p2align layout).
// The neon/hybrid small-path variants reuse the tbz tree of
// string/aarch64/memcpy-advsimd.S at the same pinned commit (already
// ported in memcpy_advsimd.zig).
//
// Port notes (the only intentional differences from upstream):
// - The C preprocessor macros of asmdefs.h are expanded: ENTRY /
//   ENTRY_ALIAS / END become explicit .globl/.type/.p2align/.size
//   directives, the register aliases (dstin, src, count, ...) become
//   architectural register names, and L(name) becomes .Lfm_sve_cpy_name.
//   Local labels are prefixed uniquely per port: module-level asm in
//   one compilation shares a label namespace across files.
// - Symbols are renamed __memcpy_aarch64_sve -> fastmem_sve_copy and
//   __memmove_aarch64_sve -> fastmem_sve_move and given .hidden
//   visibility.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - One directive is added: .p2align 6 above the alias label, so the
//   move entry is aligned in the fused module asm. Assembled standalone,
//   .text is byte-identical to upstream.
// - The whole block is gated on the SVE CPU feature and the ELF object
//   format at comptime (the directives below are ELF-only), so non-SVE
//   or non-ELF builds never see these instructions.
// - The small-size paths (count <= 64) are selected at comptime per CPU
//   model (src/aarch64/tuning.zig), separately for the copy and move
//   entries. .sve is the upstream predicated pair for 0..2*VL and the
//   upstream mid block; .neon replaces <= 64 with the tbz tree (0..15,
//   laid out so 1..3 bytes fall through every branch), one overlapping
//   16-byte pair for 16..32, and four overlapping 16-byte chunks for
//   33..64; .hybrid is the tree below 16 and the SVE pair for 16..2*VL.
//   When both entries select the same variant they share one aliased
//   head, as upstream; otherwise each entry has its own head and both
//   branch into the shared mid/long blocks. Everything above 64 bytes
//   is upstream in all variants.
//
// Why the non-sve heads exist: on Neoverse V3 the predicated SVE pair
// loses to plain NEON/scalar code below 32 bytes (fleet run
// 20260924T064442Z-aor-g2: fastmem_abi/builtin copy 1.50, move 1.40 at
// 0-16), and predicted-taken branches dominate the smallest classes, so
// the tree is laid out to minimize taken branches per class, not
// instruction count.

const builtin = @import("builtin");
const std = @import("std");
const tuning = @import("tuning.zig");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    builtin.cpu.has(.aarch64, .sve);

const copy_v = tuning.copy_small;
const move_v = tuning.move_small;
const aliased = copy_v == move_v;
const need_sve_mid = copy_v == .sve or move_v == .sve;
const need_neon_mid = copy_v != .sve or move_v != .sve;

// Upstream small head: one predicated pair covers 0..2*VL.
const head_sve =
    \\    cntb    x6
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, x6, lsl 1
    \\    b.hi    .Lfm_sve_cpy32_128
    \\
    \\    whilelo p0.b, xzr, x2
    \\    whilelo p1.b, x6, x2
    \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
    \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
    \\    st1b    z0.b, p0, [x0, 0, mul vl]
    \\    st1b    z1.b, p1, [x0, 1, mul vl]
    \\    ret
    \\
;

// The 0..15 fallthrough tree shared by the neon and hybrid heads.
// Classes are ordered so the smallest sizes take no predicted-taken
// branches: 1..3 bytes fall through (tbz tree of memcpy-advsimd.S,
// inverted). Every access is sized to the count, so guard-page tails
// stay safe; all loads precede all stores within a class, so
// overlapping moves stay correct.
fn tree(comptime p: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\    add    x4, x1, x2
        \\    add    x5, x0, x2
        \\    tbnz    x2, 3, .Lfm_sve_{s}_ge8
        \\    tbnz    x2, 2, .Lfm_sve_{s}_ge4
        \\    cbz    x2, .Lfm_sve_{s}_ret0
        \\    lsr    x14, x2, 1
        \\    ldrb    w6, [x1]
        \\    ldrb    w10, [x4, -1]
        \\    ldrb    w8, [x1, x14]
        \\    strb    w6, [x0]
        \\    strb    w8, [x0, x14]
        \\    strb    w10, [x5, -1]
        \\    ret
        \\.Lfm_sve_{s}_ge4:
        \\    ldr    w6, [x1]
        \\    ldr    w8, [x4, -4]
        \\    str    w6, [x0]
        \\    str    w8, [x5, -4]
        \\    ret
        \\.Lfm_sve_{s}_ge8:
        \\    ldr    x6, [x1]
        \\    ldr    x7, [x4, -8]
        \\    str    x6, [x0]
        \\    str    x7, [x5, -8]
        \\    ret
        \\.Lfm_sve_{s}_ret0:
        \\    ret
        \\
    , .{ p, p, p, p, p, p });
}

// Neon head: fixed boundaries, no cntb/whilelo. 16..32 is one
// overlapping 16-byte pair; the tree covers 0..15.
fn head_neon(comptime p: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\    cmp    x2, 128
        \\    b.hi    .Lfm_sve_cpy_long
        \\    cmp    x2, 32
        \\    b.hi    .Lfm_sve_cpy_gt32
        \\    cmp    x2, 16
        \\    b.hs    .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ std.fmt.comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_{s}_ge16:
        \\    add    x4, x1, x2
        \\    ldr    q0, [x1]
        \\    ldr    q1, [x4, -16]
        \\    add    x5, x0, x2
        \\    str    q0, [x0]
        \\    str    q1, [x5, -16]
        \\    ret
        \\
    , .{p});
}

// Hybrid head: the tree below 16, the predicated SVE pair for
// 16..2*VL. The cntb hoist keeps every class at one taken branch.
fn head_hybrid(comptime p: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\    cntb    x6
        \\    cmp    x2, 128
        \\    b.hi    .Lfm_sve_cpy_long
        \\    cmp    x2, x6, lsl 1
        \\    b.hi    .Lfm_sve_cpy_gt32
        \\    cmp    x2, 16
        \\    b.hs    .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ std.fmt.comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_{s}_ge16:
        \\    whilelo p0.b, xzr, x2
        \\    whilelo p1.b, x6, x2
        \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
        \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
        \\    st1b    z0.b, p0, [x0, 0, mul vl]
        \\    st1b    z1.b, p1, [x0, 1, mul vl]
        \\    ret
        \\
    , .{p});
}

fn head(comptime v: tuning.CopySmall, comptime p: []const u8) []const u8 {
    return switch (v) {
        .sve => head_sve,
        .neon => head_neon(p),
        .hybrid => head_hybrid(p),
    };
}

// Upstream mid block (33..128 via the 2*VL boundary), used by sve heads.
const mid_sve =
    \\
    \\    // Medium copies: 33..128 bytes.
    \\.Lfm_sve_cpy32_128:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy128
    \\    stp    q0, q1, [x0]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\
    \\    // Copy 65..128 bytes.
    \\.Lfm_sve_cpy128:
    \\    ldp    q4, q5, [x1, 32]
    \\    cmp    x2, 96
    \\    b.ls    .Lfm_sve_cpy96
    \\    ldp    q6, q7, [x4, -64]
    \\    stp    q6, q7, [x5, -64]
    \\.Lfm_sve_cpy96:
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// Neon mid block: 33..64 as four overlapping 16-byte chunks at 0, 16,
// n-32, n-16 (beats the ldp/stp pair block on Neoverse V3; same shape
// as the compiler-rt 16..63 class but with all loads before all
// stores), 65..128 as the upstream overlapping 32-byte chunks.
const mid_neon =
    \\
    \\    .p2align 4
    \\.Lfm_sve_cpy_gt32:
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy65_128
    \\    add    x4, x1, x2
    \\    ldr    q0, [x1]
    \\    ldr    q1, [x1, 16]
    \\    ldr    q2, [x4, -32]
    \\    ldr    q3, [x4, -16]
    \\    add    x5, x0, x2
    \\    str    q0, [x0]
    \\    str    q1, [x0, 16]
    \\    str    q2, [x5, -32]
    \\    str    q3, [x5, -16]
    \\    ret
    \\
    \\    .p2align 4
    \\    // Copy 65..128 bytes.
    \\.Lfm_sve_cpy65_128:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    ldp    q4, q5, [x1, 32]
    \\    cmp    x2, 96
    \\    b.ls    .Lfm_sve_cpy96n
    \\    ldp    q6, q7, [x4, -64]
    \\    stp    q6, q7, [x5, -64]
    \\.Lfm_sve_cpy96n:
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// Copy more than 128 bytes (upstream, shared by all heads).
const long_path =
    \\
    \\    // Copy more than 128 bytes.
    \\.Lfm_sve_cpy_long:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\
    \\    // Use backwards copy if there is an overlap.
    \\    sub    x6, x0, x1
    \\    cmp    x6, x2
    \\    b.lo    .Lfm_sve_cpy_long_backwards
    \\
    \\    // Copy 16 bytes and then align src to 16-byte alignment.
    \\    ldr    q3, [x1]
    \\    and    x6, x1, 15
    \\    bic    x1, x1, 15
    \\    sub    x3, x0, x6
    \\    add    x2, x2, x6    // Count is now 16 too large.
    \\    ldp    q0, q1, [x1, 16]
    \\    str    q3, [x0]
    \\    ldp    q2, q3, [x1, 48]
    \\    subs    x2, x2, #(128 + 16)    // Test and readjust count.
    \\    b.ls    .Lfm_sve_cpy64_from_end
    \\.Lfm_sve_cpy_loop64:
    \\    stp    q0, q1, [x3, 16]
    \\    ldp    q0, q1, [x1, 80]
    \\    stp    q2, q3, [x3, 48]
    \\    ldp    q2, q3, [x1, 112]
    \\    add    x1, x1, 64
    \\    add    x3, x3, 64
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_cpy_loop64
    \\
    \\    // Write the last iteration and copy 64 bytes from the end.
    \\.Lfm_sve_cpy64_from_end:
    \\    ldp    q4, q5, [x4, -64]
    \\    stp    q0, q1, [x3, 16]
    \\    ldp    q0, q1, [x4, -32]
    \\    stp    q2, q3, [x3, 48]
    \\    stp    q4, q5, [x5, -64]
    \\    stp    q0, q1, [x5, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\    nop
    \\
    \\    // Large backwards copy for overlapping copies.
    \\    // Copy 16 bytes and then align srcend to 16-byte alignment.
    \\.Lfm_sve_cpy_long_backwards:
    \\    cbz    x6, .Lfm_sve_cpy_return
    \\    ldr    q3, [x4, -16]
    \\    and    x6, x4, 15
    \\    bic    x4, x4, 15
    \\    sub    x2, x2, x6
    \\    ldp    q0, q1, [x4, -32]
    \\    str    q3, [x5, -16]
    \\    ldp    q2, q3, [x4, -64]
    \\    sub    x5, x5, x6
    \\    subs    x2, x2, 128
    \\    b.ls    .Lfm_sve_cpy64_from_start
    \\
    \\.Lfm_sve_cpy_loop64_backwards:
    \\    str    q1, [x5, -16]
    \\    str    q0, [x5, -32]
    \\    ldp    q0, q1, [x4, -96]
    \\    str    q3, [x5, -48]
    \\    str    q2, [x5, -64]!
    \\    ldp    q2, q3, [x4, -128]
    \\    sub    x4, x4, 64
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_cpy_loop64_backwards
    \\
    \\    // Write the last iteration and copy 64 bytes from the start.
    \\.Lfm_sve_cpy64_from_start:
    \\    ldp    q4, q5, [x1, 32]
    \\    stp    q0, q1, [x5, -32]
    \\    ldp    q0, q1, [x1]
    \\    stp    q2, q3, [x5, -64]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q0, q1, [x0]
    \\.Lfm_sve_cpy_return:
    \\    ret
    \\
;

// Both entries share the mid and long blocks. The shared section keeps
// the split move head adjacent to copy, including its original padding.
comptime {
    if (enabled) {
        @export(&moveEntry, .{ .name = "fastmem_sve_move", .visibility = .hidden });
        @export(&copyEntry, .{ .name = "fastmem_sve_copy", .visibility = .hidden });
    }
}

pub const moveEntry = if (aliased) copyEntry else splitMoveEntry;

fn splitMoveEntry() align(64) linksection(".text.fastmem_sve_pair") callconv(.naked) void {
    asm volatile (".arch armv8-a+sve\n    hint 34\n" ++ head(move_v, "mov") ++ ".p2align 6\n" ::: .{ .memory = true });
}

pub fn copyEntry() align(64) linksection(".text.fastmem_sve_pair") callconv(.naked) void {
    asm volatile (".arch armv8-a+sve\n    hint 34\n" ++ head(copy_v, "cpy") ++
            (if (need_sve_mid) mid_sve else "") ++
            (if (need_neon_mid) mid_neon else "") ++ long_path ::: .{ .memory = true });
}

pub const fastmem_sve_copy: *const fn ([*]u8, [*]const u8, usize) callconv(.c) void = @ptrCast(&copyEntry);
pub const fastmem_sve_move: *const fn ([*]u8, [*]const u8, usize) callconv(.c) void = @ptrCast(&moveEntry);
