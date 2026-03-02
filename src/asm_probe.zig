//! Probe file for disassembly inspection. Exports fastmem and builtin
//! memory operations with C ABI so they appear as named symbols in the
//! emitted assembly. Compile as an object in ReleaseFast:
//!
//!     zig build asm                       # native target
//!     zig build asm-all                   # all key targets
//!     zig build asm -Dtarget=x86_64-linux-gnu  # specific target

const fastmem = @import("fastmem");

export fn fastmem_copy(dst: [*]u8, src: [*]const u8, len: usize) void {
    fastmem.copy(u8, dst[0..len], src[0..len]);
}

export fn fastmem_move(dst: [*]u8, src: [*]const u8, len: usize) void {
    fastmem.move(u8, dst[0..len], src[0..len]);
}

export fn builtin_memcpy(dst: [*]u8, src: [*]const u8, len: usize) void {
    @memcpy(dst[0..len], src[0..len]);
}

export fn builtin_memmove(dst: [*]u8, src: [*]const u8, len: usize) void {
    @memmove(dst[0..len], src[0..len]);
}
