//! Compile-fail fixture: a package consumer cannot reach the dispatch test
//! hook. build.zig expects the @compileError of `fastmem.dispatch.force`.
const fastmem = @import("fastmem");

pub fn main() void {
    fastmem.dispatch.force(.generic) catch |err| @panic(@errorName(err));
}
