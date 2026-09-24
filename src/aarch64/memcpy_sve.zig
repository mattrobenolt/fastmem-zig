// memcpy - copy memory area
//
// Copyright (c) 2019-2023, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memcpy-sve.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534 (includes 23c4393006122497,
// "Improve __memcpy_aarch64_sve": the cntb hoist and .p2align layout).
//
// Port notes (the only intentional differences from upstream):
// - The C preprocessor macros of asmdefs.h are expanded: ENTRY /
//   ENTRY_ALIAS / END become explicit .globl/.type/.p2align/.size
//   directives, the register aliases (dstin, src, count, ...) become
//   architectural register names, and L(name) becomes .Lname.
// - Symbols are renamed __memcpy_aarch64_sve -> fastmem_sve_copy and
//   __memmove_aarch64_sve -> fastmem_sve_move and given .hidden
//   visibility.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions use #( ...) so the integrated assembler
//   parses them.
// - The whole block is gated on the SVE CPU feature and the ELF object
//   format at comptime (the directives below are ELF-only), so non-SVE
//   or non-ELF builds never see these instructions.

const builtin = @import("builtin");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    builtin.cpu.has(.aarch64, .sve);

comptime {
    if (enabled) {
        asm (
            \\.text
            \\.arch armv8-a+sve
            \\
            \\// ENTRY_ALIAS (__memmove_aarch64_sve)
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
            \\    cntb    x6
            \\    cmp    x2, 128
            \\    b.hi    .Lcopy_long
            \\    cmp    x2, x6, lsl 1
            \\    b.hi    .Lcopy32_128
            \\
            \\    whilelo p0.b, xzr, x2
            \\    whilelo p1.b, x6, x2
            \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
            \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
            \\    st1b    z0.b, p0, [x0, 0, mul vl]
            \\    st1b    z1.b, p1, [x0, 1, mul vl]
            \\    ret
            \\
            \\    // Medium copies: 33..128 bytes.
            \\.Lcopy32_128:
            \\    add    x4, x1, x2
            \\    add    x5, x0, x2
            \\    ldp    q0, q1, [x1]
            \\    ldp    q2, q3, [x4, -32]
            \\    cmp    x2, 64
            \\    b.hi    .Lcopy128
            \\    stp    q0, q1, [x0]
            \\    stp    q2, q3, [x5, -32]
            \\    ret
            \\
            \\    .p2align 4
            \\
            \\    // Copy 65..128 bytes.
            \\.Lcopy128:
            \\    ldp    q4, q5, [x1, 32]
            \\    cmp    x2, 96
            \\    b.ls    .Lcopy96
            \\    ldp    q6, q7, [x4, -64]
            \\    stp    q6, q7, [x5, -64]
            \\.Lcopy96:
            \\    stp    q0, q1, [x0]
            \\    stp    q4, q5, [x0, 32]
            \\    stp    q2, q3, [x5, -32]
            \\    ret
            \\
            \\    // Copy more than 128 bytes.
            \\.Lcopy_long:
            \\    add    x4, x1, x2
            \\    add    x5, x0, x2
            \\
            \\    // Use backwards copy if there is an overlap.
            \\    sub    x6, x0, x1
            \\    cmp    x6, x2
            \\    b.lo    .Lcopy_long_backwards
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
            \\    b.ls    .Lcopy64_from_end
            \\.Lloop64:
            \\    stp    q0, q1, [x3, 16]
            \\    ldp    q0, q1, [x1, 80]
            \\    stp    q2, q3, [x3, 48]
            \\    ldp    q2, q3, [x1, 112]
            \\    add    x1, x1, 64
            \\    add    x3, x3, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lloop64
            \\
            \\    // Write the last iteration and copy 64 bytes from the end.
            \\.Lcopy64_from_end:
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
            \\.Lcopy_long_backwards:
            \\    cbz    x6, .Lreturn
            \\    ldr    q3, [x4, -16]
            \\    and    x6, x4, 15
            \\    bic    x4, x4, 15
            \\    sub    x2, x2, x6
            \\    ldp    q0, q1, [x4, -32]
            \\    str    q3, [x5, -16]
            \\    ldp    q2, q3, [x4, -64]
            \\    sub    x5, x5, x6
            \\    subs    x2, x2, 128
            \\    b.ls    .Lcopy64_from_start
            \\
            \\.Lloop64_backwards:
            \\    str    q1, [x5, -16]
            \\    str    q0, [x5, -32]
            \\    ldp    q0, q1, [x4, -96]
            \\    str    q3, [x5, -48]
            \\    str    q2, [x5, -64]!
            \\    ldp    q2, q3, [x4, -128]
            \\    sub    x4, x4, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lloop64_backwards
            \\
            \\    // Write the last iteration and copy 64 bytes from the start.
            \\.Lcopy64_from_start:
            \\    ldp    q4, q5, [x1, 32]
            \\    stp    q0, q1, [x5, -32]
            \\    ldp    q0, q1, [x1]
            \\    stp    q2, q3, [x5, -64]
            \\    stp    q4, q5, [x0, 32]
            \\    stp    q0, q1, [x0]
            \\.Lreturn:
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
