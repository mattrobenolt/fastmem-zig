const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("dlfcn.h");
});

extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

const Probe = struct {
    name: []const u8,
    addr: usize,
    library_path: []const u8,
    library_base: usize,
    symbol_name: ?[]const u8,
    symbol_addr: ?usize,
};

const Report = struct {
    version: u8 = 1,
    os: []const u8,
    arch: []const u8,
    abi: []const u8,
    functions: [2]Probe,
};

fn probeSymbol(name: []const u8, func: *const anyopaque) !Probe {
    var info: c.Dl_info = mem.zeroes(c.Dl_info);
    if (c.dladdr(func, &info) == 0) {
        return error.DladdrFailed;
    }

    return .{
        .name = name,
        .addr = @intFromPtr(func),
        .library_path = if (info.dli_fname != null) mem.span(info.dli_fname) else "",
        .library_base = if (info.dli_fbase != null) @intFromPtr(info.dli_fbase) else 0,
        .symbol_name = if (info.dli_sname != null) mem.span(info.dli_sname) else null,
        .symbol_addr = if (info.dli_saddr != null) @intFromPtr(info.dli_saddr) else null,
    };
}

pub fn main(init: std.process.Init) !void {
    const memcpy_ptr: *const anyopaque = @ptrCast(&memcpy);
    const memmove_ptr: *const anyopaque = @ptrCast(&memmove);

    const report: Report = .{
        .os = @tagName(builtin.target.os.tag),
        .arch = @tagName(builtin.target.cpu.arch),
        .abi = @tagName(builtin.target.abi),
        .functions = .{
            try probeSymbol("memcpy", memcpy_ptr),
            try probeSymbol("memmove", memmove_ptr),
        },
    };

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}
