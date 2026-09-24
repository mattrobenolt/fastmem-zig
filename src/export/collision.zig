const fastmem = @import("fastmem");
const options = @import("collision_options");

comptime {
    fastmem.exportSymbols();
    switch (options.kind) {
        .strong => @export(&replacement, .{
            .name = options.symbol,
            .linkage = .strong,
            .visibility = .hidden,
        }),
        .weak => @export(&replacement, .{ .name = options.symbol, .linkage = .weak }),
        .compiler_rt => {},
        .default => @export(&replacement, .{ .name = options.symbol }),
    }
}

fn replacement() callconv(.c) void {}
