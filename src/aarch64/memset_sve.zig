// memset - fill memory with a constant byte
//
// Copyright (c) 2024-2024, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memset-sve.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534.
//
// Port notes (the only intentional differences from upstream):
// - The C preprocessor macros of asmdefs.h are expanded: ENTRY / END
//   become explicit .globl/.type/.p2align/.size directives, the
//   register aliases (dstin, valw, count, ...) become architectural
//   register names, and L(name) becomes .Lname.
// - The symbol is renamed __memset_aarch64_sve -> fastmem_sve_set and
//   given .hidden visibility.
// - SKIP_ZVA_CHECK is not defined, so the runtime DCZID_EL0 check on
//   the ZVA path is kept, as upstream writes it without the define.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - The whole block is gated on the SVE CPU feature at comptime, so
//   non-SVE builds never see these instructions.

const builtin = @import("builtin");

const enabled = builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .sve);

comptime {
    if (enabled) {
        asm (
            \\.text
            \\.arch armv8-a+sve
            \\
            \\// ENTRY (__memset_aarch64_sve)
            \\.p2align 6
            \\.globl fastmem_sve_set
            \\.hidden fastmem_sve_set
            \\.type fastmem_sve_set, %function
            \\fastmem_sve_set:
            \\.cfi_startproc
            \\hint 34
            \\    dup    v0.16b, w1
            \\    cmp    x2, 16
            \\    b.lo    .Lset_16
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
            \\.Lset_16:
            \\    whilelo p0.b, xzr, x2
            \\    st1b    z0.b, p0, [x0]
            \\    ret
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
            \\    cmp    x2, 256
            \\    b.lo    .Lno_zva
            \\    tst    w1, 255
            \\    b.ne    .Lno_zva
            \\
            \\    mrs    x5, dczid_el0
            \\    and    x5, x5, 31
            \\    cmp    x5, 4        // ZVA size is 64 bytes.
            \\    b.ne    .Lno_zva
            \\
            \\    str    q0, [x0]
            \\    str    q0, [x3, 16]
            \\    bic    x3, x0, 31
            \\    stp    q0, q0, [x3, 32]
            \\    bic    x3, x0, 63
            \\    sub    x2, x4, x3    // Count is now 64 too large.
            \\    sub    x2, x2, 128    // Adjust count and bias for loop.
            \\
            \\    sub    x8, x4, 1    // Write last bytes before ZVA loop.
            \\    bic    x8, x8, 15
            \\    stp    q0, q0, [x8, -48]
            \\    str    q0, [x8, -16]
            \\    str    q0, [x4, -16]
            \\
            \\    .p2align 4
            \\.Lzva64_loop:
            \\    add    x3, x3, 64
            \\    dc    zva, x3
            \\    subs    x2, x2, 64
            \\    b.hi    .Lzva64_loop
            \\    ret
            \\
            \\.Lno_zva:
            \\    str    q0, [x0]
            \\    sub    x2, x4, x3    // Count is 16 too large.
            \\    sub    x2, x2, #(64 + 16)    // Adjust count and bias for loop.
            \\.Lno_zva_loop:
            \\    stp    q0, q0, [x3, 16]
            \\    stp    q0, q0, [x3, 48]
            \\    add    x3, x3, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lno_zva_loop
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\    ret
            \\
            \\// END (__memset_aarch64_sve)
            \\.cfi_endproc
            \\.size fastmem_sve_set, .-fastmem_sve_set
        );
    }
}

pub extern fn fastmem_sve_set(dst: [*]u8, val: u8, len: usize) void;
