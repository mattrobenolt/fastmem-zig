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
// - The small-size path (count <= 64) is selected at comptime per CPU
//   model (src/aarch64/tuning.zig): the upstream predicated SVE pair
//   (.sve), the advsimd tbz tree below 32 (.neon), or the tree below 16
//   with the SVE pair for 16..2*VL (.hybrid). Everything above the
//   small path is upstream in all variants.

const builtin = @import("builtin");
const tuning = @import("tuning.zig");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    builtin.cpu.has(.aarch64, .sve);

// Upstream small path: one predicated pair covers 0..2*VL.
const small_sve =
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

// Neon small path: fixed boundaries, no cntb/whilelo. 16..32 is one
// overlapping 16-byte pair; below 16 branches to the tbz tree.
const small_neon =
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, 32
    \\    b.hi    .Lfm_sve_cpy32_128
    \\
    \\    cmp    x2, 16
    \\    b.lo    .Lfm_sve_cpy0_15
    \\    add    x4, x1, x2
    \\    ldr    q0, [x1]
    \\    ldr    q1, [x4, -16]
    \\    add    x5, x0, x2
    \\    str    q0, [x0]
    \\    str    q1, [x5, -16]
    \\    ret
    \\
;

// Hybrid small path: tbz tree below 16, the predicated SVE pair for
// 16..2*VL.
const small_hybrid =
    \\    cntb    x6
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, x6, lsl 1
    \\    b.hi    .Lfm_sve_cpy32_128
    \\
    \\    cmp    x2, 16
    \\    b.lo    .Lfm_sve_cpy0_15
    \\    whilelo p0.b, xzr, x2
    \\    whilelo p1.b, x6, x2
    \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
    \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
    \\    st1b    z0.b, p0, [x0, 0, mul vl]
    \\    st1b    z1.b, p1, [x0, 1, mul vl]
    \\    ret
    \\
;

// Small copies: 0..15 bytes. The tbz tree is the memcpy-advsimd.S
// small path at the same pinned commit; every access is sized to the
// count, so guard-page tails stay safe. All loads precede all stores
// within each class, so overlapping moves stay correct.
const small_tree =
    \\    .p2align 4
    \\.Lfm_sve_cpy0_15:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    tbz    x2, 3, .Lfm_sve_cpy0_7
    \\    ldr    x6, [x1]
    \\    ldr    x7, [x4, -8]
    \\    str    x6, [x0]
    \\    str    x7, [x5, -8]
    \\    ret
    \\
    \\.Lfm_sve_cpy0_7:
    \\    tbz    x2, 2, .Lfm_sve_cpy0_3
    \\    ldr    w6, [x1]
    \\    ldr    w8, [x4, -4]
    \\    str    w6, [x0]
    \\    str    w8, [x5, -4]
    \\    ret
    \\
    \\.Lfm_sve_cpy0_3:
    \\    cbz    x2, .Lfm_sve_cpy0_done
    \\    lsr    x14, x2, 1
    \\    ldrb    w6, [x1]
    \\    ldrb    w10, [x4, -1]
    \\    ldrb    w8, [x1, x14]
    \\    strb    w6, [x0]
    \\    strb    w8, [x0, x14]
    \\    strb    w10, [x5, -1]
    \\.Lfm_sve_cpy0_done:
    \\    ret
    \\
;

const small_head = switch (tuning.copy_small) {
    .sve => small_sve,
    .neon => small_neon,
    .hybrid => small_hybrid,
};

const small_block = if (tuning.copy_small == .sve) "" else small_tree;

comptime {
    if (enabled) {
        asm (
            \\.text
            \\.arch armv8-a+sve
            \\
            \\// ENTRY_ALIAS (__memmove_aarch64_sve)
            \\// The alias label is 64-byte aligned too: in the
            \\// fused module
            \\// asm this block can start at an unaligned offset, and the
            \\// copy entry's alignment below must not leave the move entry
            \\// on a run of NOPs (it would lose the BTI landing pad). The
            \\// standalone .text stays byte-identical to upstream.
            \\.p2align 6
            \\.globl fastmem_sve_move
            \\.hidden fastmem_sve_move
            \\.type fastmem_sve_move, %function
            \\fastmem_sve_move:
            \\// ENTRY (__memcpy_aarch64_sve)
            \\.p2align 6
            \\.globl fastmem_sve_copy
            \\.hidden fastmem_sve_copy
            \\.type fastmem_sve_copy, %function
            \\fastmem_sve_copy:
            \\.cfi_startproc
            \\hint 34
            \\
            ++ small_head ++
            \\
            ++ small_block ++
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
            \\// END (__memcpy_aarch64_sve)
            \\.cfi_endproc
            \\.size fastmem_sve_copy, .-fastmem_sve_copy
        );
    }
}

pub extern fn fastmem_sve_copy(dst: [*]u8, src: [*]const u8, len: usize) void;
pub extern fn fastmem_sve_move(dst: [*]u8, src: [*]const u8, len: usize) void;
