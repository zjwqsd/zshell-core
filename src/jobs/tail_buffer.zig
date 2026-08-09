const std = @import("std");

pub const TailBuffer = struct {
    pub const ReadSlice = struct {
        bytes: []const u8,
        start_offset: u64,
        next_offset: u64,
        truncated: bool,
    };

    pub const ReadError = error{CursorAheadOfStream};

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

    pub fn readAfter(self: *const TailBuffer, after: ?u64) ReadError!ReadSlice {
        const retained_start = self.total_bytes - @as(u64, @intCast(self.len));
        const requested_start = after orelse 0;
        if (requested_start > self.total_bytes) return error.CursorAheadOfStream;

        const start_offset = @max(requested_start, retained_start);
        const relative_start: usize = @intCast(start_offset - retained_start);
        return .{
            .bytes = self.data[relative_start..self.len],
            .start_offset = start_offset,
            .next_offset = self.total_bytes,
            .truncated = requested_start < retained_start,
        };
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

test "tail buffer supports incremental reads" {
    const allocator = std.testing.allocator;
    var buffer = try TailBuffer.init(allocator, 8);
    defer buffer.deinit(allocator);

    buffer.append("abcdef");
    const first = try buffer.readAfter(null);
    try std.testing.expectEqualStrings("abcdef", first.bytes);
    try std.testing.expectEqual(@as(u64, 0), first.start_offset);
    try std.testing.expectEqual(@as(u64, 6), first.next_offset);
    try std.testing.expect(!first.truncated);

    buffer.append("ghij");
    const incremental = try buffer.readAfter(6);
    try std.testing.expectEqualStrings("ghij", incremental.bytes);
    try std.testing.expectEqual(@as(u64, 6), incremental.start_offset);
    try std.testing.expectEqual(@as(u64, 10), incremental.next_offset);
    try std.testing.expect(!incremental.truncated);

    const stale = try buffer.readAfter(1);
    try std.testing.expectEqualStrings("cdefghij", stale.bytes);
    try std.testing.expectEqual(@as(u64, 2), stale.start_offset);
    try std.testing.expectEqual(@as(u64, 10), stale.next_offset);
    try std.testing.expect(stale.truncated);

    try std.testing.expectError(error.CursorAheadOfStream, buffer.readAfter(11));
}
