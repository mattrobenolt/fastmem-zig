//! Runtime CPU dispatch for x86_64 builds whose target CPU lacks AVX2
//! (docs/runtime-dispatch.md). The kernels of each level come from a
//! separate object that build.zig compiles for a fixed CPU. This module
//! reads CPUID and XCR0 once, on the first call, and sets one function
//! pointer per operation.
//!
//! The pointers start at resolver functions, like a lazy PLT entry. The
//! first call through any pointer selects the level, stores all three
//! pointers, and tail-calls the selected kernel. Every later call loads
//! the pointer and makes one indirect jump. There is no global constructor.
//! Concurrent first calls store the same values, so the race is benign; the
//! atomics only make it defined.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("fastmem_options");
const cpuid = @import("cpuid.zig");
const generic = @import("../generic.zig");

pub const Level = cpuid.Level;
pub const Info = cpuid.Info;

/// True when this build dispatches: an x86_64 Linux target without AVX2,
/// with the level objects that build.zig links into the fastmem module.
pub const enabled = builtin.cpu.arch == .x86_64 and
    builtin.os.tag == .linux and
    builtin.target.ofmt == .elf and
    !builtin.cpu.has(.x86, .avx2) and
    @hasDecl(options, "x86_dispatch") and options.x86_dispatch;

/// All dispatch symbols start with this prefix. The instance id is unique
/// per package instance (build.zig `instanceId`), so that two fastmem
/// packages in one link do not collide.
pub const symbol_prefix = "fastmem_x86_" ++
    (if (@hasDecl(options, "x86_instance")) options.x86_instance else "none") ++ "_";

const tail: std.builtin.CallModifier = if (builtin.zig_backend == .stage2_llvm)
    .always_tail
else
    .auto;

pub const CopyFn = *const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) ?*anyopaque;
pub const SetFn = *const fn (?*anyopaque, c_int, usize) callconv(.c) ?*anyopaque;
const NameFn = *const fn () callconv(.c) [*:0]const u8;

const Kernels = struct {
    copy: CopyFn,
    move: CopyFn,
    set: SetFn,
    name: NameFn,
};

fn kernels(comptime l: Level) Kernels {
    if (l == .generic) return .{
        .copy = &generic.memcpy,
        .move = &generic.memmove,
        .set = &generic.memset,
        .name = &genericName,
    };
    const prefix = symbol_prefix ++ @tagName(l) ++ "_";
    // x86 memcpy is the memmove kernel, as in the comptime builds.
    const move = @extern(CopyFn, .{ .name = prefix ++ "memmove", .visibility = .hidden });
    return .{
        .copy = move,
        .move = move,
        .set = @extern(SetFn, .{ .name = prefix ++ "memset", .visibility = .hidden }),
        .name = @extern(NameFn, .{ .name = prefix ++ "name", .visibility = .hidden }),
    };
}

fn genericName() callconv(.c) [*:0]const u8 {
    @disableIntrinsics();
    return "zig-simd";
}

var copy_fn: CopyFn = &resolveCopy;
var move_fn: CopyFn = &resolveMove;
var set_fn: SetFn = &resolveSet;
const unresolved = std.math.maxInt(u8);
var selected: u8 = unresolved;

comptime {
    if (enabled) {
        // Hidden names make the resolvers and the generic level visible to
        // the recursion audit (src/export/check.py) and to the benchmark
        // codegen evidence. They never reach .dynsym.
        const hidden: std.builtin.SymbolVisibility = .hidden;
        const p = symbol_prefix;
        @export(&resolveCopy, .{ .name = p ++ "resolve_memcpy", .visibility = hidden });
        @export(&resolveMove, .{ .name = p ++ "resolve_memmove", .visibility = hidden });
        @export(&resolveSet, .{ .name = p ++ "resolve_memset", .visibility = hidden });
        @export(&generic.memcpy, .{ .name = p ++ "generic_memcpy", .visibility = hidden });
        @export(&generic.memmove, .{ .name = p ++ "generic_memmove", .visibility = hidden });
        @export(&generic.memset, .{ .name = p ++ "generic_memset", .visibility = hidden });
    }
}

/// The C-ABI entries: a pointer load and an indirect jump. LLVM 21 does
/// not fold the load into `jmp *mem` (src/x86_64/check_dispatch.py pins
/// the two instructions).
pub fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    return @call(tail, copyPointer(), .{ dest, src, n });
}

pub fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    return @call(tail, movePointer(), .{ dest, src, n });
}

pub fn memset(dest: ?*anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    return @call(tail, setPointer(), .{ dest, c, n });
}

/// The large paths of the inline layer call the pointers directly, with
/// no entry jump.
pub inline fn copyPointer() CopyFn {
    return @atomicLoad(CopyFn, &copy_fn, .monotonic);
}

pub inline fn movePointer() CopyFn {
    return @atomicLoad(CopyFn, &move_fn, .monotonic);
}

pub inline fn setPointer() SetFn {
    return @atomicLoad(SetFn, &set_fn, .monotonic);
}

fn resolveCopy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    install(detect().select());
    return @call(tail, copyPointer(), .{ dest, src, n });
}

fn resolveMove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    install(detect().select());
    return @call(tail, movePointer(), .{ dest, src, n });
}

fn resolveSet(dest: ?*anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    install(detect().select());
    return @call(tail, setPointer(), .{ dest, c, n });
}

fn install(l: Level) void {
    @disableIntrinsics();
    switch (l) {
        inline else => |known| {
            const k = comptime kernels(known);
            @atomicStore(CopyFn, &copy_fn, k.copy, .monotonic);
            @atomicStore(CopyFn, &move_fn, k.move, .monotonic);
            @atomicStore(SetFn, &set_fn, k.set, .monotonic);
        },
    }
    @atomicStore(u8, &selected, @intFromEnum(l), .monotonic);
}

/// The selected level. The first use resolves it.
pub fn level() Level {
    @disableIntrinsics();
    if (@atomicLoad(u8, &selected, .monotonic) == unresolved) install(detect().select());
    return @enumFromInt(@atomicLoad(u8, &selected, .monotonic));
}

/// The kernel implementation name of the selected level (the
/// `fastmem.impl` name of a comptime build for that CPU).
pub fn kernelName() [:0]const u8 {
    @disableIntrinsics();
    return switch (level()) {
        inline else => |l| std.mem.span((comptime kernels(l)).name()),
    };
}

/// Select a level instead of the detected one: a test hook. The level
/// must be supported by this CPU. Calls that are in progress on other
/// threads finish in the kernel that they entered.
pub fn force(l: Level) error{Unsupported}!void {
    @disableIntrinsics();
    if (!detect().supports(l)) return error.Unsupported;
    install(l);
}

/// Read CPUID and XCR0. The function makes no memory calls: it runs
/// inside the first memcpy, memmove, or memset of the process.
pub fn detect() Info {
    @disableIntrinsics();
    const leaf0 = cpuidLeaf(0, 0);
    const leaf1 = if (leaf0.eax >= 1) cpuidLeaf(1, 0) else Regs.zero;
    const leaf7 = if (leaf0.eax >= 7) cpuidLeaf(7, 0) else Regs.zero;
    const ext_max = cpuidLeaf(0x8000_0000, 0).eax;
    const ext1 = if (ext_max >= 0x8000_0001) cpuidLeaf(0x8000_0001, 0) else Regs.zero;
    const osxsave = leaf1.ecx & (1 << 27) != 0;
    return .decode(.{
        .vendor_ebx = leaf0.ebx,
        .leaf1_eax = leaf1.eax,
        .leaf1_ecx = leaf1.ecx,
        .leaf7_ebx = leaf7.ebx,
        .ext1_ecx = ext1.ecx,
        .xcr0 = if (osxsave) xgetbv0() else 0,
    });
}

const Regs = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,

    const zero: Regs = .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
};

fn cpuidLeaf(leaf: u32, subleaf: u32) Regs {
    @disableIntrinsics();
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv0() u64 {
    @disableIntrinsics();
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("xgetbv"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [index] "{ecx}" (@as(u32, 0)),
    );
    return @as(u64, edx) << 32 | eax;
}
