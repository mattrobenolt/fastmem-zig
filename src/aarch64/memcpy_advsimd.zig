// memcpy - copy memory area
//
// Copyright (c) 2019-2023, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memcpy-advsimd.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534. This is the generic
// aarch64 (non-SVE) kernel, the G6 baseline.
//
// Port notes (the only intentional differences from upstream):
// - The C preprocessor macros of asmdefs.h are expanded: ENTRY /
//   ENTRY_ALIAS / END become explicit .globl/.type/.p2align/.size
//   directives, the register aliases (dstin, src, count, ...) become
//   architectural register names, and L(name) becomes .Lfm_simd_cpy_name.
//   Local labels are prefixed uniquely per port: module-level asm in
//   one compilation shares a label namespace across files.
// - Symbols are renamed __memcpy_aarch64_simd -> fastmem_advsimd_copy
//   and __memmove_aarch64_simd -> fastmem_advsimd_move and given
//   .hidden visibility.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - One directive is added: .p2align 6 above the alias label, so the
//   move entry is aligned in the fused module asm. Assembled standalone,
//   .text is byte-identical to upstream.
// - The whole block is gated on the absence of the SVE CPU feature and
//   on the ELF object format at comptime (the directives below are
//   ELF-only), so non-ELF or SVE builds never see these
//   instructions.

const builtin = @import("builtin");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    !builtin.cpu.has(.aarch64, .sve);

comptime {
    if (enabled) {
        asm (
            \\.text
            \\
            \\// ENTRY_ALIAS (__memmove_aarch64_simd)
            \\// The alias label is 64-byte aligned too: in the
            \\// fused module
            \\// asm this block can start at an unaligned offset, and the
            \\// copy entry's alignment below must not leave the move entry
            \\// on a run of NOPs (it would lose the BTI landing pad). The
            \\// standalone .text stays byte-identical to upstream.
            \\.p2align 6
            \\.globl fastmem_advsimd_move
            \\.hidden fastmem_advsimd_move
            \\.type fastmem_advsimd_move, %function
            \\fastmem_advsimd_move:
            \\// ENTRY (__memcpy_aarch64_simd)
            \\.p2align 6
            \\.globl fastmem_advsimd_copy
            \\.hidden fastmem_advsimd_copy
            \\.type fastmem_advsimd_copy, %function
            \\fastmem_advsimd_copy:
            \\.cfi_startproc
            \\hint 34
            \\    add    x4, x1, x2
            \\    cmp    x2, 128
            \\    b.hi    .Lfm_simd_cpy_long
            \\    add    x5, x0, x2
            \\    cmp    x2, 32
            \\    b.hi    .Lfm_simd_cpy32_128
            \\    nop
            \\
            \\    // Small copies: 0..32 bytes.
            \\    cmp    x2, 16
            \\    b.lo    .Lfm_simd_cpy16
            \\    ldr    q0, [x1]
            \\    ldr    q1, [x4, -16]
            \\    str    q0, [x0]
            \\    str    q1, [x5, -16]
            \\    ret
            \\
            \\    .p2align 4
            \\    // Medium copies: 33..128 bytes.
            \\.Lfm_simd_cpy32_128:
            \\    ldp    q0, q1, [x1]
            \\    ldp    q2, q3, [x4, -32]
            \\    cmp    x2, 64
            \\    b.hi    .Lfm_simd_cpy128
            \\    stp    q0, q1, [x0]
            \\    stp    q2, q3, [x5, -32]
            \\    ret
            \\
            \\    .p2align 4
            \\    // Copy 8-15 bytes.
            \\.Lfm_simd_cpy16:
            \\    tbz    x2, 3, .Lfm_simd_cpy8
            \\    ldr    x6, [x1]
            \\    ldr    x7, [x4, -8]
            \\    str    x6, [x0]
            \\    str    x7, [x5, -8]
            \\    ret
            \\
            \\    // Copy 4-7 bytes.
            \\.Lfm_simd_cpy8:
            \\    tbz    x2, 2, .Lfm_simd_cpy4
            \\    ldr    w6, [x1]
            \\    ldr    w8, [x4, -4]
            \\    str    w6, [x0]
            \\    str    w8, [x5, -4]
            \\    ret
            \\
            \\    // Copy 65..128 bytes.
            \\.Lfm_simd_cpy128:
            \\    ldp    q4, q5, [x1, 32]
            \\    cmp    x2, 96
            \\    b.ls    .Lfm_simd_cpy96
            \\    ldp    q6, q7, [x4, -64]
            \\    stp    q6, q7, [x5, -64]
            \\.Lfm_simd_cpy96:
            \\    stp    q0, q1, [x0]
            \\    stp    q4, q5, [x0, 32]
            \\    stp    q2, q3, [x5, -32]
            \\    ret
            \\
            \\    // Copy 0..3 bytes using a branchless sequence.
            \\.Lfm_simd_cpy4:
            \\    cbz    x2, .Lfm_simd_cpy0
            \\    lsr    x14, x2, 1
            \\    ldrb    w6, [x1]
            \\    ldrb    w10, [x4, -1]
            \\    ldrb    w8, [x1, x14]
            \\    strb    w6, [x0]
            \\    strb    w8, [x0, x14]
            \\    strb    w10, [x5, -1]
            \\.Lfm_simd_cpy0:
            \\    ret
            \\
            \\    .p2align 3
            \\    // Copy more than 128 bytes.
            \\.Lfm_simd_cpy_long:
            \\    add    x5, x0, x2
            \\
            \\    // Use backwards copy if there is an overlap.
            \\    sub    x14, x0, x1
            \\    cmp    x14, x2
            \\    b.lo    .Lfm_simd_cpy_long_backwards
            \\
            \\    // Copy 16 bytes and then align src to 16-byte alignment.
            \\    ldr    q3, [x1]
            \\    and    x14, x1, 15
            \\    bic    x1, x1, 15
            \\    sub    x3, x0, x14
            \\    add    x2, x2, x14    // Count is now 16 too large.
            \\    ldp    q0, q1, [x1, 16]
            \\    str    q3, [x0]
            \\    ldp    q2, q3, [x1, 48]
            \\    subs    x2, x2, #(128 + 16)    // Test and readjust count.
            \\    b.ls    .Lfm_simd_cpy64_from_end
            \\.Lfm_simd_cpy_loop64:
            \\    stp    q0, q1, [x3, 16]
            \\    ldp    q0, q1, [x1, 80]
            \\    stp    q2, q3, [x3, 48]
            \\    ldp    q2, q3, [x1, 112]
            \\    add    x1, x1, 64
            \\    add    x3, x3, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lfm_simd_cpy_loop64
            \\
            \\    // Write the last iteration and copy 64 bytes from the end.
            \\.Lfm_simd_cpy64_from_end:
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
            \\.Lfm_simd_cpy_long_backwards:
            \\    cbz    x14, .Lfm_simd_cpy0
            \\    ldr    q3, [x4, -16]
            \\    and    x14, x4, 15
            \\    bic    x4, x4, 15
            \\    sub    x2, x2, x14
            \\    ldp    q0, q1, [x4, -32]
            \\    str    q3, [x5, -16]
            \\    ldp    q2, q3, [x4, -64]
            \\    sub    x5, x5, x14
            \\    subs    x2, x2, 128
            \\    b.ls    .Lfm_simd_cpy64_from_start
            \\
            \\.Lfm_simd_cpy_loop64_backwards:
            \\    str    q1, [x5, -16]
            \\    str    q0, [x5, -32]
            \\    ldp    q0, q1, [x4, -96]
            \\    str    q3, [x5, -48]
            \\    str    q2, [x5, -64]!
            \\    ldp    q2, q3, [x4, -128]
            \\    sub    x4, x4, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lfm_simd_cpy_loop64_backwards
            \\
            \\    // Write the last iteration and copy 64 bytes from the start.
            \\.Lfm_simd_cpy64_from_start:
            \\    ldp    q4, q5, [x1, 32]
            \\    stp    q0, q1, [x5, -32]
            \\    ldp    q0, q1, [x1]
            \\    stp    q2, q3, [x5, -64]
            \\    stp    q4, q5, [x0, 32]
            \\    stp    q0, q1, [x0]
            \\    ret
            \\
            \\// END (__memcpy_aarch64_simd)
            \\.cfi_endproc
            \\.size fastmem_advsimd_copy, .-fastmem_advsimd_copy
        );
    }
}

pub extern fn fastmem_advsimd_copy(dst: [*]u8, src: [*]const u8, len: usize) void;
pub extern fn fastmem_advsimd_move(dst: [*]u8, src: [*]const u8, len: usize) void;
