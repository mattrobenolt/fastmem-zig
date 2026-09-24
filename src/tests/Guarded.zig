//! One reusable accessible window between two inaccessible pages.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const heap = std.heap;
const mem = std.mem;
const Guarded = @This();

mapping: []align(heap.page_size_min) u8,
bytes: []u8,

pub fn init(capacity: u32) !Guarded {
    const page = heap.pageSize();
    const size = mem.alignForward(usize, capacity, page);
    const mapping = try posix.mmap(
        null,
        size + 2 * page,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer posix.munmap(mapping);
    const bytes = mapping[page..][0..size];
    const rc = linux.mprotect(bytes.ptr, bytes.len, .{ .READ = true, .WRITE = true });
    if (linux.errno(rc) != .SUCCESS)
        return error.ProtectFailed;
    return .{ .mapping = mapping, .bytes = bytes };
}

pub fn deinit(self: Guarded) void {
    posix.munmap(self.mapping);
}

pub const Side = enum { start, end };

pub fn offset(self: Guarded, side: Side, len: u32, inset: u32) u32 {
    return switch (side) {
        .start => inset,
        .end => @as(u32, @intCast(self.bytes.len)) - len - inset,
    };
}
