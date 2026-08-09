const std = @import("std");
const Source = @import("../runtime/source.zig").Source;

pub const capacity: usize = 512;
pub const message_capacity: usize = 1024;

pub const Resource = enum {
    control,
    execution,
    job,
    shell,
    shellcore,
};

const Entry = struct {
    seq: u64 = 0,
    source: Source = .system,
    kind: [64]u8 = [_]u8{0} ** 64,
    kind_len: usize = 0,
    resource: Resource = .shellcore,
    resource_id: ?u64 = null,
    message: [message_capacity]u8 = [_]u8{0} ** message_capacity,
    message_len: usize = 0,
    message_truncated: bool = false,
};

pub const PublicEvent = struct {
    seq: u64,
    source: []const u8,
    kind: []u8,
    resource: []const u8,
    resourceId: ?u64,
    message: []u8,
    messageTruncated: bool,
};

pub const Snapshot = struct {
    items: []PublicEvent,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.kind);
            allocator.free(item.message);
        }
        allocator.free(self.items);
    }
};

var mutex: std.Io.Mutex = .init;
var entries: [capacity]Entry = [_]Entry{.{}} ** capacity;
var next_seq: u64 = 1;
var count: usize = 0;

pub fn record(
    io: std.Io,
    source: Source,
    kind: []const u8,
    resource: Resource,
    resource_id: ?u64,
    message: []const u8,
) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const seq = next_seq;
    next_seq += 1;
    const index: usize = @intCast((seq - 1) % @as(u64, capacity));
    var entry = &entries[index];

    const kind_len = @min(kind.len, entry.kind.len);
    @memcpy(entry.kind[0..kind_len], kind[0..kind_len]);

    const message_len = @min(message.len, entry.message.len);
    @memcpy(entry.message[0..message_len], message[0..message_len]);

    entry.seq = seq;
    entry.source = source;
    entry.kind_len = kind_len;
    entry.resource = resource;
    entry.resource_id = resource_id;
    entry.message_len = message_len;
    entry.message_truncated = message.len > entry.message.len;

    if (count < capacity) count += 1;
}

pub fn snapshot(allocator: std.mem.Allocator, io: std.Io) !Snapshot {
    return snapshotRecent(allocator, io, capacity);
}

pub fn snapshotRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    max_items: usize,
) !Snapshot {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const item_count = @min(count, max_items);
    const items = try allocator.alloc(PublicEvent, item_count);
    errdefer allocator.free(items);

    const first_seq = next_seq - @as(u64, @intCast(item_count));
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.kind);
            allocator.free(item.message);
        }
    }

    for (0..item_count) |offset| {
        const seq = first_seq + @as(u64, @intCast(offset));
        const index: usize = @intCast((seq - 1) % @as(u64, capacity));
        const entry = &entries[index];

        const kind_copy = try allocator.dupe(u8, entry.kind[0..entry.kind_len]);
        const message_copy = allocator.dupe(u8, entry.message[0..entry.message_len]) catch |err| {
            allocator.free(kind_copy);
            return err;
        };

        items[offset] = .{
            .seq = entry.seq,
            .source = entry.source.name(),
            .kind = kind_copy,
            .resource = @tagName(entry.resource),
            .resourceId = entry.resource_id,
            .message = message_copy,
            .messageTruncated = entry.message_truncated,
        };
        initialized += 1;
    }

    return .{ .items = items };
}
