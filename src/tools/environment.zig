const std = @import("std");
const builtin = @import("builtin");

pub const Info = struct {
    os: []const u8,
    arch: []const u8,
    zig_version: []const u8,
    cwd: [:0]u8,

    pub fn deinit(self: Info, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
    }
};

pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
) !Info {
    return .{
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .zig_version = builtin.zig_version_string,
        .cwd = try std.process.currentPathAlloc(io, allocator),
    };
}

test "collect environment info" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const info = try collect(allocator, io);
    defer info.deinit(allocator);

    try std.testing.expect(info.os.len > 0);
    try std.testing.expect(info.arch.len > 0);
    try std.testing.expect(info.zig_version.len > 0);
    try std.testing.expect(info.cwd.len > 0);
}
