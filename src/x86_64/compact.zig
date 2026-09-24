//! Branch-light short copies adapted from Zig compiler-rt (MIT).
// Copyright (c) Zig contributors
// SPDX-License-Identifier: MIT
// Upstream: lib/compiler_rt/memmove.zig, copyRange4 and copyLessThan16.
// Commit: 24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8 (0.16.0).
// Scalar/vector pointer accesses replace arrays to avoid LLVM stack spills.
// The caller supplies the size checks. THIRD_PARTY.md contains the MIT notice.
const ops = @import("ops.zig");

/// The caller guarantees 1 <= n <= 3.
pub inline fn bytes(dst: [*]u8, src: [*]const u8, n: usize) void {
    const middle = n / 2;
    const a = src[0];
    const b = src[middle];
    const c = src[n - 1];
    dst[0] = a;
    dst[middle] = b;
    dst[n - 1] = c;
}

/// The caller guarantees sizeof(T) <= n < 4 * sizeof(T).
pub inline fn quad(comptime T: type, dst: [*]u8, src: [*]const u8, n: usize) void {
    const step = (n & (2 * @sizeOf(T))) / 2;
    const last = n - @sizeOf(T);
    const penultimate = last - step;
    const a = ops.load(T, src);
    const b = ops.load(T, src + step);
    const c = ops.load(T, src + penultimate);
    const d = ops.load(T, src + last);
    ops.store(T, dst, a);
    ops.store(T, dst + step, b);
    ops.store(T, dst + penultimate, c);
    ops.store(T, dst + last, d);
}
