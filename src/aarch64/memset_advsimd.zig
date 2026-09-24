// memset - fill memory with a constant byte
//
// Copyright (c) 2012-2024, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memset.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534. This is the generic
// aarch64 (non-SVE) kernel, the G6 baseline.
//
// Port notes (the only intentional differences from upstream):
// - The C preprocessor macros of asmdefs.h are expanded: ENTRY / END
//   become explicit .globl/.type/.p2align/.size directives, the
//   register aliases (dstin, valw, count, ...) become architectural
//   register names, L(name) becomes .Lname, and the numeric local
//   labels (2:, 3:) are kept as-is.
// - The symbol is renamed __memset_aarch64 -> fastmem_advsimd_set and
//   given .hidden visibility.
// - SKIP_ZVA_CHECK is not defined, so the runtime DCZID_EL0 check on
//   the ZVA path is kept, as upstream writes it without the define.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - The whole block is gated on the absence of the SVE CPU feature and
//   on the ELF object format at comptime (the directives below are
//   ELF-only); the local labels collide with memset_sve.zig only if
//   both are emitted, which the complementary gates prevent.

const builtin = @import("builtin");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    !builtin.cpu.has(.aarch64, .sve);

comptime {
    if (enabled) {
        asm (
            \\.text
            \\
            \\// ENTRY (__memset_aarch64)
            \\.p2align 6
            \\.globl fastmem_advsimd_set
            \\.hidden fastmem_advsimd_set
            \\.type fastmem_advsimd_set, %function
            \\fastmem_advsimd_set:
            \\.cfi_startproc
            \\hint 34
            \\    dup    v0.16B, w1
            \\    cmp    x2, 16
            \\    b.lo    .Lset_small
            \\
            \\    add    x4, x0, x2
            \\    cmp    x2, 64
            \\    b.hi    .Lset_128
            \\
            \\    // Set 16..64 bytes.
            \\    mov    x3, 48
            \\    and    x3, x3, x2, lsr 1
            \\    sub    x5, x4, x3
            \\    str    q0, [x0]
            \\    str    q0, [x0, x3]
            \\    str    q0, [x5, -16]
            \\    str    q0, [x4, -16]
            \\    ret
            \\
            \\    .p2align 4
            \\    // Set 0..15 bytes.
            \\.Lset_small:
            \\    add    x4, x0, x2
            \\    cmp    x2, 4
            \\    b.lo    2f
            \\    lsr    x3, x2, 3
            \\    sub    x5, x4, x3, lsl 2
            \\    str    s0, [x0]
            \\    str    s0, [x0, x3, lsl 2]
            \\    str    s0, [x5, -4]
            \\    str    s0, [x4, -4]
            \\    ret
            \\
            \\    // Set 0..3 bytes.
            \\2:  cbz    x2, 3f
            \\    lsr    x3, x2, 1
            \\    strb    w1, [x0]
            \\    strb    w1, [x0, x3]
            \\    strb    w1, [x4, -1]
            \\3:  ret
            \\
            \\    .p2align 4
            \\.Lset_128:
            \\    bic    x3, x0, 15
            \\    cmp    x2, 128
            \\    b.hi    .Lset_long
            \\    stp    q0, q0, [x0]
            \\    stp    q0, q0, [x0, 32]
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\    ret
            \\
            \\    .p2align 4
            \\.Lset_long:
            \\    str    q0, [x0]
            \\    str    q0, [x3, 16]
            \\    tst    w1, 255
            \\    b.ne    .Lno_zva
            \\    mrs    x5, dczid_el0
            \\    and    x5, x5, 31
            \\    cmp    x5, 4        // ZVA size is 64 bytes.
            \\    b.ne    .Lno_zva
            \\    stp    q0, q0, [x3, 32]
            \\    bic    x3, x0, 63
            \\    sub    x2, x4, x3    // Count is now 64 too large.
            \\    sub    x2, x2, #(64 + 64)    // Adjust count and bias for loop.
            \\
            \\    // Write last bytes before ZVA loop.
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\
            \\    .p2align 4
            \\.Lzva64_loop:
            \\    add    x3, x3, 64
            \\    dc    zva, x3
            \\    subs    x2, x2, 64
            \\    b.hi    .Lzva64_loop
            \\    ret
            \\
            \\    .p2align 3
            \\.Lno_zva:
            \\    sub    x2, x4, x3    // Count is 32 too large.
            \\    sub    x2, x2, #(64 + 32)    // Adjust count and bias for loop.
            \\.Lno_zva_loop:
            \\    stp    q0, q0, [x3, 32]
            \\    stp    q0, q0, [x3, 64]
            \\    add    x3, x3, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lno_zva_loop
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\    ret
            \\
            \\// END (__memset_aarch64)
            \\.cfi_endproc
            \\.size fastmem_advsimd_set, .-fastmem_advsimd_set
        );
    }
}

pub extern fn fastmem_advsimd_set(dst: [*]u8, val: u8, len: usize) void;
