const fastmem = @import("fastmem");

pub fn main() !void {
    fastmem.copy(u8, &.{}, &.{});
}
