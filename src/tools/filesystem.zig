const std = @import("std");

pub const default_read_bytes: usize = 256 * 1024;
pub const max_read_bytes: usize = 1024 * 1024;
pub const default_list_entries: usize = 200;
pub const max_list_entries: usize = 1000;
pub const max_write_bytes: usize = 4 * 1024 * 1024;

pub const StatResult = struct {
    path: []const u8,
    kind: []const u8,
    size: u64,
    mtime_ms: i64,
};

pub const ListEntry = struct {
    name: []u8,
    kind: []const u8,
    size: ?u64,
};

pub const ListResult = struct {
    path: []const u8,
    entries: []ListEntry,
    next_offset: usize,
    eof: bool,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.name);
        allocator.free(self.entries);
    }
};

pub const ReadInput = struct {
    path: []const u8,
    offset: u64 = 0,
    max_bytes: usize = default_read_bytes,
};

pub const ReadResult = struct {
    path: []const u8,
    data: []u8,
    size: u64,
    offset: u64,
    next_offset: u64,
    eof: bool,

    pub fn deinit(self: ReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const WriteInput = struct {
    path: []const u8,
    data: []const u8,
    append: bool = false,
};

pub const WriteResult = struct {
    path: []const u8,
    bytes_written: usize,
    size: u64,
    appended: bool,
};

pub const MkdirResult = struct {
    path: []const u8,
    recursive: bool,
};

pub fn stat(io: std.Io, path: []const u8) !StatResult {
    if (path.len == 0) return error.EmptyPath;
    const info = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    return .{
        .path = path,
        .kind = @tagName(info.kind),
        .size = info.size,
        .mtime_ms = info.mtime.toMilliseconds(),
    };
}

pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    offset: usize,
    max_entries: usize,
) !ListResult {
    if (path.len == 0) return error.EmptyPath;
    if (max_entries == 0 or max_entries > max_list_entries) return error.InvalidListLimit;

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var items: std.ArrayList(ListEntry) = .empty;
    errdefer {
        for (items.items) |entry| allocator.free(entry.name);
        items.deinit(allocator);
    }

    var iterator = dir.iterate();
    var seen: usize = 0;
    var eof = true;
    while (try iterator.next(io)) |entry| {
        if (seen < offset) {
            seen += 1;
            continue;
        }
        if (items.items.len == max_entries) {
            eof = false;
            break;
        }

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);

        const size: ?u64 = if (entry.kind == .file)
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch null) |info| info.size else null
        else
            null;

        try items.append(allocator, .{
            .name = name,
            .kind = @tagName(entry.kind),
            .size = size,
        });
        seen += 1;
    }

    const owned = try items.toOwnedSlice(allocator);
    return .{
        .path = path,
        .entries = owned,
        .next_offset = offset + owned.len,
        .eof = eof,
    };
}

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: ReadInput,
) !ReadResult {
    if (input.path.len == 0) return error.EmptyPath;
    if (input.max_bytes == 0 or input.max_bytes > max_read_bytes) return error.InvalidReadLimit;

    var file = try std.Io.Dir.cwd().openFile(io, input.path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);

    const info = try file.stat(io);
    if (input.offset > info.size) return error.OffsetBeyondEnd;

    const remaining = info.size - input.offset;
    const requested: usize = @intCast(@min(remaining, @as(u64, @intCast(input.max_bytes))));
    var data = try allocator.alloc(u8, requested);
    errdefer allocator.free(data);

    const read_len = try file.readPositionalAll(io, data, input.offset);
    if (read_len != data.len) data = try allocator.realloc(data, read_len);

    const next_offset = input.offset + @as(u64, @intCast(data.len));
    return .{
        .path = input.path,
        .data = data,
        .size = info.size,
        .offset = input.offset,
        .next_offset = next_offset,
        .eof = next_offset >= info.size,
    };
}

pub fn write(io: std.Io, input: WriteInput) !WriteResult {
    if (input.path.len == 0) return error.EmptyPath;
    if (input.data.len > max_write_bytes) return error.WriteTooLarge;

    var file = try std.Io.Dir.cwd().createFile(io, input.path, .{
        .read = input.append,
        .truncate = !input.append,
    });
    defer file.close(io);

    if (input.append) {
        const before = try file.stat(io);
        try file.writePositionalAll(io, input.data, before.size);
    } else {
        try file.writePositionalAll(io, input.data, 0);
    }

    const after = try file.stat(io);
    return .{
        .path = input.path,
        .bytes_written = input.data.len,
        .size = after.size,
        .appended = input.append,
    };
}

pub fn mkdir(io: std.Io, path: []const u8, recursive: bool) !MkdirResult {
    if (path.len == 0) return error.EmptyPath;
    if (recursive) {
        try std.Io.Dir.cwd().createDirPath(io, path);
    } else {
        try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    }
    return .{ .path = path, .recursive = recursive };
}
