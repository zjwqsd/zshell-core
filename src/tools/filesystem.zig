const std = @import("std");

pub const default_read_bytes: usize = 256 * 1024;
pub const max_read_bytes: usize = 1024 * 1024;
pub const default_list_entries: usize = 200;
pub const max_list_entries: usize = 1000;
pub const max_write_bytes: usize = 4 * 1024 * 1024;
pub const default_search_results: usize = 100;
pub const max_search_results: usize = 1000;
pub const max_search_file_bytes: usize = 4 * 1024 * 1024;

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

pub const SearchInput = struct {
    path: []const u8 = ".",
    query: []const u8,
    glob: ?[]const u8 = null,
    max_results: usize = default_search_results,
};

pub const SearchMatch = struct {
    path: []u8,
    line: usize,
    column: usize,
    text: []u8,
};

pub const SearchResult = struct {
    path: []const u8,
    query: []const u8,
    matches: []SearchMatch,
    truncated: bool,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        for (self.matches) |match| {
            allocator.free(match.path);
            allocator.free(match.text);
        }
        allocator.free(self.matches);
    }
};

pub const PatchInput = struct {
    path: []const u8,
    patch: []const u8,
};

pub const PatchResult = struct {
    path: []const u8,
    hunks_applied: usize,
    size: u64,
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

    var final_size: u64 = undefined;
    if (input.append) {
        const before = try file.stat(io);
        try file.writePositionalAll(io, input.data, before.size);
        final_size = before.size + @as(u64, @intCast(input.data.len));
    } else {
        try file.writePositionalAll(io, input.data, 0);
        final_size = @as(u64, @intCast(input.data.len));
    }

    return .{
        .path = input.path,
        .bytes_written = input.data.len,
        .size = final_size,
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

pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: SearchInput,
) !SearchResult {
    if (input.path.len == 0) return error.EmptyPath;
    if (input.query.len == 0) return error.EmptyQuery;
    if (input.max_results == 0 or input.max_results > max_search_results) return error.InvalidSearchLimit;

    var root = try std.Io.Dir.cwd().openDir(io, input.path, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(allocator);
    defer walker.deinit();

    var matches: std.ArrayList(SearchMatch) = .empty;
    errdefer {
        for (matches.items) |match| {
            allocator.free(match.path);
            allocator.free(match.text);
        }
        matches.deinit(allocator);
    }

    var truncated = false;
    walk: while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        if (input.glob) |pattern| {
            const candidate = if (std.mem.indexOfScalar(u8, pattern, '/') != null or
                std.mem.indexOfScalar(u8, pattern, '\\') != null)
                entry.path
            else
                entry.basename;
            if (!wildcardMatch(pattern, candidate)) continue;
        }

        const info = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (info.size > max_search_file_bytes) continue;

        const data = entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(max_search_file_bytes + 1),
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(data);
        if (!std.unicode.utf8ValidateSlice(data)) continue;

        var line_start: usize = 0;
        var line_number: usize = 1;
        while (line_start <= data.len) : (line_number += 1) {
            const newline = std.mem.indexOfScalarPos(u8, data, line_start, '\n');
            const line_end = newline orelse data.len;
            var line = data[line_start..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            if (std.mem.indexOf(u8, line, input.query)) |column| {
                if (matches.items.len == input.max_results) {
                    truncated = true;
                    break :walk;
                }

                const result_path = if (std.mem.eql(u8, input.path, "."))
                    try allocator.dupe(u8, entry.path)
                else
                    try std.fs.path.join(allocator, &.{ input.path, entry.path });
                errdefer allocator.free(result_path);
                const text = try allocator.dupe(u8, line);
                errdefer allocator.free(text);
                try matches.append(allocator, .{
                    .path = result_path,
                    .line = line_number,
                    .column = column + 1,
                    .text = text,
                });
            }

            if (newline == null) break;
            line_start = line_end + 1;
        }
    }

    return .{
        .path = input.path,
        .query = input.query,
        .matches = try matches.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

pub fn patch(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PatchInput,
) !PatchResult {
    if (input.path.len == 0) return error.EmptyPath;
    if (input.patch.len == 0) return error.EmptyPatch;
    if (input.patch.len > max_write_bytes) return error.PatchTooLarge;

    const original = std.Io.Dir.cwd().readFileAlloc(
        io,
        input.path,
        allocator,
        .limited(max_write_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.WriteTooLarge,
        else => return err,
    };
    defer allocator.free(original);
    if (!std.unicode.utf8ValidateSlice(original)) return error.NotUtf8;

    const applied = try applyUnifiedPatch(allocator, original, input.patch);
    defer allocator.free(applied.data);
    if (applied.data.len > max_write_bytes) return error.WriteTooLarge;

    const result = try write(io, .{ .path = input.path, .data = applied.data });
    return .{
        .path = input.path,
        .hunks_applied = applied.hunks_applied,
        .size = result.size,
    };
}

const AppliedPatch = struct {
    data: []u8,
    hunks_applied: usize,
};

const SourceLine = struct {
    content: []const u8,
    full: []const u8,
};

const HunkHeader = struct {
    old_start: usize,
    old_count: usize,
    new_count: usize,
};

fn applyUnifiedPatch(
    allocator: std.mem.Allocator,
    original: []const u8,
    patch_text: []const u8,
) !AppliedPatch {
    var source_lines: std.ArrayList(SourceLine) = .empty;
    defer source_lines.deinit(allocator);
    try splitSourceLines(allocator, original, &source_lines);

    const newline_style: []const u8 = if (std.mem.indexOf(u8, original, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var source_index: usize = 0;
    var patch_pos: usize = 0;
    var hunks: usize = 0;
    var pending_line: ?[]const u8 = null;

    while (true) {
        const raw = if (pending_line) |line| blk: {
            pending_line = null;
            break :blk line;
        } else nextTextLine(patch_text, &patch_pos) orelse break;
        const line = trimTrailingCr(raw);

        if (!std.mem.startsWith(u8, line, "@@ ")) {
            if (hunks == 0 and (line.len == 0 or
                std.mem.startsWith(u8, line, "diff ") or
                std.mem.startsWith(u8, line, "index ") or
                std.mem.startsWith(u8, line, "--- ") or
                std.mem.startsWith(u8, line, "+++ ")))
            {
                continue;
            }
            return error.InvalidPatch;
        }

        const header = try parseHunkHeader(line);
        const target_index = if (header.old_count == 0)
            header.old_start
        else if (header.old_start == 0)
            0
        else
            header.old_start - 1;
        if (target_index < source_index or target_index > source_lines.items.len) return error.PatchContextMismatch;
        while (source_index < target_index) : (source_index += 1) {
            try out.appendSlice(allocator, source_lines.items[source_index].full);
        }

        var old_seen: usize = 0;
        var new_seen: usize = 0;
        var last_was_add = false;
        while (nextTextLine(patch_text, &patch_pos)) |body_raw| {
            const body = trimTrailingCr(body_raw);
            if (std.mem.startsWith(u8, body, "@@ ")) {
                pending_line = body;
                break;
            }
            if (body.len == 0) return error.InvalidPatch;

            const payload = body[1..];
            switch (body[0]) {
                ' ' => {
                    if (source_index >= source_lines.items.len or
                        !std.mem.eql(u8, source_lines.items[source_index].content, payload))
                        return error.PatchContextMismatch;
                    try out.appendSlice(allocator, source_lines.items[source_index].full);
                    source_index += 1;
                    old_seen += 1;
                    new_seen += 1;
                    last_was_add = false;
                },
                '-' => {
                    if (source_index >= source_lines.items.len or
                        !std.mem.eql(u8, source_lines.items[source_index].content, payload))
                        return error.PatchContextMismatch;
                    source_index += 1;
                    old_seen += 1;
                    last_was_add = false;
                },
                '+' => {
                    try out.appendSlice(allocator, payload);
                    try out.appendSlice(allocator, newline_style);
                    new_seen += 1;
                    last_was_add = true;
                },
                '\\' => {
                    if (!std.mem.eql(u8, body, "\\ No newline at end of file")) return error.InvalidPatch;
                    if (last_was_add and std.mem.endsWith(u8, out.items, newline_style)) {
                        out.shrinkRetainingCapacity(out.items.len - newline_style.len);
                    }
                    last_was_add = false;
                },
                else => return error.InvalidPatch,
            }
        }

        if (old_seen != header.old_count or new_seen != header.new_count) return error.InvalidPatch;
        hunks += 1;
    }

    if (hunks == 0) return error.InvalidPatch;
    while (source_index < source_lines.items.len) : (source_index += 1) {
        try out.appendSlice(allocator, source_lines.items[source_index].full);
    }

    return .{ .data = try out.toOwnedSlice(allocator), .hunks_applied = hunks };
}

fn splitSourceLines(
    allocator: std.mem.Allocator,
    data: []const u8,
    lines: *std.ArrayList(SourceLine),
) !void {
    var start: usize = 0;
    while (start < data.len) {
        const newline = std.mem.indexOfScalarPos(u8, data, start, '\n');
        const end = newline orelse data.len;
        var content_end = end;
        if (content_end > start and data[content_end - 1] == '\r') content_end -= 1;
        const full_end = if (newline != null) end + 1 else end;
        try lines.append(allocator, .{
            .content = data[start..content_end],
            .full = data[start..full_end],
        });
        if (newline == null) break;
        start = end + 1;
    }
}

fn nextTextLine(text: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= text.len) return null;
    const newline = std.mem.indexOfScalarPos(u8, text, pos.*, '\n');
    const end = newline orelse text.len;
    const line = text[pos.*..end];
    pos.* = if (newline != null) end + 1 else text.len;
    return line;
}

fn trimTrailingCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn parseHunkHeader(line: []const u8) !HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.InvalidPatch;
    const old_begin: usize = 4;
    const old_end = std.mem.indexOfScalarPos(u8, line, old_begin, ' ') orelse return error.InvalidPatch;
    if (old_end + 2 >= line.len or line[old_end + 1] != '+') return error.InvalidPatch;
    const new_begin = old_end + 2;
    const new_end = std.mem.indexOfScalarPos(u8, line, new_begin, ' ') orelse return error.InvalidPatch;
    if (!std.mem.startsWith(u8, line[new_end..], " @@")) return error.InvalidPatch;

    const old_range = try parseHunkRange(line[old_begin..old_end]);
    const new_range = try parseHunkRange(line[new_begin..new_end]);
    return .{
        .old_start = old_range.start,
        .old_count = old_range.count,
        .new_count = new_range.count,
    };
}

const HunkRange = struct { start: usize, count: usize };

fn parseHunkRange(text: []const u8) !HunkRange {
    if (text.len == 0) return error.InvalidPatch;
    if (std.mem.indexOfScalar(u8, text, ',')) |comma| {
        if (comma == 0 or comma + 1 >= text.len) return error.InvalidPatch;
        return .{
            .start = std.fmt.parseInt(usize, text[0..comma], 10) catch return error.InvalidPatch,
            .count = std.fmt.parseInt(usize, text[comma + 1 ..], 10) catch return error.InvalidPatch,
        };
    }
    return .{
        .start = std.fmt.parseInt(usize, text, 10) catch return error.InvalidPatch,
        .count = 1,
    };
}

fn wildcardByteEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    const a_sep = a == '/' or a == '\\';
    const b_sep = b == '/' or b == '\\';
    return a_sep and b_sep;
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry_text: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or wildcardByteEqual(pattern[p], text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry_text = t;
        } else if (star) |star_pos| {
            p = star_pos + 1;
            retry_text += 1;
            t = retry_text;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "unified patch applies multiple hunks with context validation" {
    const original = "alpha\nbeta\ngamma\ndelta\n";
    const diff =
        "@@ -1,3 +1,3 @@\n" ++
        " alpha\n" ++
        "-beta\n" ++
        "+BETA\n" ++
        " gamma\n" ++
        "@@ -4,1 +4,2 @@\n" ++
        " delta\n" ++
        "+epsilon\n";
    const applied = try applyUnifiedPatch(std.testing.allocator, original, diff);
    defer std.testing.allocator.free(applied.data);
    try std.testing.expectEqual(@as(usize, 2), applied.hunks_applied);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\ndelta\nepsilon\n", applied.data);
}

test "unified patch supports zero-count insertion hunks" {
    const diff = "@@ -1,0 +2,1 @@\n+inserted\n";
    const applied = try applyUnifiedPatch(std.testing.allocator, "first\nsecond\n", diff);
    defer std.testing.allocator.free(applied.data);
    try std.testing.expectEqualStrings("first\ninserted\nsecond\n", applied.data);
}

test "unified patch rejects mismatched context" {
    const diff = "@@ -1,1 +1,1 @@\n-wrong\n+new\n";
    try std.testing.expectError(
        error.PatchContextMismatch,
        applyUnifiedPatch(std.testing.allocator, "old\n", diff),
    );
}

test "wildcard matcher supports star and question mark" {
    try std.testing.expect(wildcardMatch("*.zig", "filesystem.zig"));
    try std.testing.expect(wildcardMatch("src/?ain.zig", "src/main.zig"));
    try std.testing.expect(wildcardMatch("src/*.zig", "src\\main.zig"));
    try std.testing.expect(!wildcardMatch("*.go", "filesystem.zig"));
}

test "search finds text recursively with glob" {
    const result = try search(std.testing.allocator, std.testing.io, .{
        .path = "src/tools",
        .query = "pub fn stat",
        .glob = "*.zig",
        .max_results = 10,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.matches.len >= 1);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].path, "filesystem.zig"));
}
