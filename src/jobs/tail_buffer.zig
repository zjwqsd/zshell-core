const std = @import("std");

pub const TailBuffer = struct {
    data: []u8,
    len: usize = 0,
    total_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TailBuffer {
        return .{ .data = try allocator.alloc(u8, capacity) };
    }

    pub fn deinit(self: *TailBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }

    pub fn append(self: *TailBuffer, chunk: []const u8) void {
        if (chunk.len == 0) return;

        self.total_bytes += chunk.len;
        const capacity = self.data.len;

        if (chunk.len >= capacity) {
            const tail = chunk[chunk.len - capacity ..];
            @memcpy(self.data[0..capacity], tail);
            self.len = capacity;
            return;
        }

        if (self.len + chunk.len <= capacity) {
            @memcpy(self.data[self.len .. self.len + chunk.len], chunk);
            self.len += chunk.len;
            return;
        }

        const old_keep = capacity - chunk.len;
        if (old_keep > 0) {
            const old_start = self.len - old_keep;
            std.mem.copyForwards(
                u8,
                self.data[0..old_keep],
                self.data[old_start..self.len],
            );
        }

        @memcpy(self.data[old_keep .. old_keep + chunk.len], chunk);
        self.len = old_keep + chunk.len;
    }

    pub fn slice(self: *const TailBuffer) []const u8 {
        return self.data[0..self.len];
    }

    pub fn truncated(self: *const TailBuffer) bool {
        return self.total_bytes > self.len;
    }
};

test "tail buffer retains recent bytes" {
    const allocator = std.testing.allocator;
    var buffer = try TailBuffer.init(allocator, 8);
    defer buffer.deinit(allocator);

    buffer.append("abcd");
    buffer.append("ef");
    try std.testing.expectEqualStrings("abcdef", buffer.slice());
    try std.testing.expect(!buffer.truncated());

    buffer.append("ghij");
    try std.testing.expectEqualStrings("cdefghij", buffer.slice());
    try std.testing.expect(buffer.truncated());
}

test "tail buffer handles oversized chunk" {
    const allocator = std.testing.allocator;
    var buffer = try TailBuffer.init(allocator, 5);
    defer buffer.deinit(allocator);

    buffer.append("0123456789");
    try std.testing.expectEqualStrings("56789", buffer.slice());
    try std.testing.expect(buffer.truncated());
}
