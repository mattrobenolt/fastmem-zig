//! Runtime, C-ABI, and constant-size entry paths through the same public API.
const fastmem = @import("fastmem");

pub const Op = enum { copy, move, set };
pub const Path = enum { runtime, abi, constant };
const CopyFn = *const fn ([*]u8, [*]const u8, usize) callconv(.c) [*]u8;
const SetFn = *const fn ([*]u8, c_int, usize) callconv(.c) [*]u8;
var copy_fn: CopyFn = &kernelCopy;
var move_fn: CopyFn = &kernelMove;
var set_fn: SetFn = &kernelSet;

noinline fn kernelCopy(dest: [*]u8, source: [*]const u8, len: usize) callconv(.c) [*]u8 {
    return @ptrCast(fastmem.abi.memcpy(dest, source, len).?);
}

noinline fn kernelMove(dest: [*]u8, source: [*]const u8, len: usize) callconv(.c) [*]u8 {
    return @ptrCast(fastmem.abi.memmove(dest, source, len).?);
}

noinline fn kernelSet(dest: [*]u8, value: c_int, len: usize) callconv(.c) [*]u8 {
    return @ptrCast(fastmem.abi.memset(dest, value, len).?);
}

comptime {
    @export(&kernelCopy, .{ .name = "fastmem_copy" });
    @export(&kernelMove, .{ .name = "fastmem_move" });
    if (@hasDecl(fastmem, "set")) @export(&kernelSet, .{ .name = "fastmem_set" });
}

fn direct(comptime op: Op, dest: []u8, source: []const u8, value: u8) void {
    switch (op) {
        .copy => fastmem.copy(u8, dest, source),
        .move => fastmem.move(u8, dest, source),
        .set => if (@hasDecl(fastmem, "set")) fastmem.set(u8, dest, value),
    }
}

const FixedFn = *const fn ([]u8, []const u8, u8) void;
fn fixed(comptime op: Op, comptime len: u32) FixedFn {
    return &struct {
        fn run(dest: []u8, source: []const u8, value: u8) void {
            // Keep the length comptime at the public call, not only at this wrapper's caller.
            switch (op) {
                .copy => fastmem.copy(u8, dest[0..len], source[0..len]),
                .move => fastmem.move(u8, dest[0..len], source[0..len]),
                .set => if (@hasDecl(fastmem, "set")) fastmem.set(u8, dest[0..len], value),
            }
        }
    }.run;
}

pub fn call(comptime op: Op, path: Path, dest: []u8, source: []const u8, value: u8) void {
    switch (path) {
        .runtime => direct(op, dest, source, value),
        .abi => {
            const returned = switch (op) {
                .copy => @as(*volatile CopyFn, &copy_fn).*(dest.ptr, source.ptr, dest.len),
                .move => @as(*volatile CopyFn, &move_fn).*(dest.ptr, source.ptr, dest.len),
                .set => @as(*volatile SetFn, &set_fn).*(dest.ptr, value, dest.len),
            };
            if (returned != dest.ptr)
                @panic("The C-ABI return pointer differs from the destination.");
        },
        .constant => {
            const table = comptime table: {
                @setEvalBranchQuota(10000);
                var functions: [256]FixedFn = undefined;
                for (&functions, 1..) |*function, len| function.* = fixed(op, len);
                break :table functions;
            };
            table[dest.len - 1](dest, source, value);
        },
    }
}
