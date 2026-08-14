const std = @import("std");

const filesystem = @import("../tools/filesystem.zig");
const output = @import("output.zig");

pub const Outcome = enum {
    ok,
    bad_request,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: []const u8,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?Outcome {
    if (std.mem.eql(u8, operation, "file_stat")) {
        return @as(?Outcome, try fileStat(io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_list")) {
        return @as(?Outcome, try fileList(allocator, io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_read")) {
        return @as(?Outcome, try fileRead(allocator, io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_search")) {
        return @as(?Outcome, try fileSearch(allocator, io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_write")) {
        return @as(?Outcome, try fileWrite(allocator, io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_patch")) {
        return @as(?Outcome, try filePatch(allocator, io, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "file_mkdir")) {
        return @as(?Outcome, try fileMkdir(io, arguments, writer));
    }

    return null;
}

fn fileStat(
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const path = try parseRequiredPath(arguments, writer) orelse return .bad_request;
    const result = filesystem.stat(io, path) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to stat path");
        return .ok;
    };

    try writeSuccess(writer, .{
        .path = result.path,
        .kind = result.kind,
        .size = result.size,
        .mtimeMs = result.mtime_ms,
    }, false);
    return .ok;
}

fn fileList(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseFileListInput(arguments, writer) orelse return .bad_request;
    const result = filesystem.list(
        allocator,
        io,
        input.path,
        input.offset,
        input.max_entries,
    ) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to list directory");
        return .ok;
    };
    defer result.deinit(allocator);

    const PublicEntry = struct {
        name: []const u8,
        kind: []const u8,
        size: ?u64,
    };
    const entries = try allocator.alloc(PublicEntry, result.entries.len);
    defer allocator.free(entries);
    for (result.entries, entries) |entry, *public| {
        public.* = .{ .name = entry.name, .kind = entry.kind, .size = entry.size };
    }

    try writeSuccess(writer, .{
        .path = result.path,
        .entries = entries,
        .nextOffset = result.next_offset,
        .eof = result.eof,
    }, false);
    return .ok;
}

fn fileRead(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseFileReadInput(arguments, writer) orelse return .bad_request;
    const result = filesystem.read(allocator, io, input) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to read file");
        return .ok;
    };
    defer result.deinit(allocator);

    const encoded = try output.encode(allocator, result.data);
    defer encoded.deinit(allocator);

    try writeSuccess(writer, .{
        .path = result.path,
        .size = result.size,
        .offset = result.offset,
        .nextOffset = result.next_offset,
        .eof = result.eof,
        .content = .{
            .encoding = encoded.encoding,
            .data = encoded.data,
        },
    }, false);
    return .ok;
}

fn fileSearch(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseFileSearchInput(arguments, writer) orelse return .bad_request;
    const result = filesystem.search(allocator, io, input) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to search files");
        return .ok;
    };
    defer result.deinit(allocator);

    try writeSuccess(writer, .{
        .path = result.path,
        .query = result.query,
        .matches = result.matches,
        .truncated = result.truncated,
    }, false);
    return .ok;
}

fn filePatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseFilePatchInput(arguments, writer) orelse return .bad_request;
    const result = filesystem.patch(allocator, io, input) catch |err| {
        try writeFailure(writer, @errorName(err), switch (err) {
            error.InvalidPatch => "Patch is not a valid unified diff",
            error.PatchContextMismatch => "Patch context does not match the current file",
            else => "Failed to patch file",
        });
        return .ok;
    };

    try writeSuccess(writer, .{
        .path = result.path,
        .hunksApplied = result.hunks_applied,
        .size = result.size,
    }, false);
    return .ok;
}

fn fileWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const parsed = try parseFileWriteInput(allocator, arguments, writer) orelse return .bad_request;
    defer if (parsed.owned_data) |data| allocator.free(data);

    const result = filesystem.write(io, parsed.input) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to write file");
        return .ok;
    };

    try writeSuccess(writer, .{
        .path = result.path,
        .bytesWritten = result.bytes_written,
        .size = result.size,
        .appended = result.appended,
    }, false);
    return .ok;
}

fn fileMkdir(
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseFileMkdirInput(arguments, writer) orelse return .bad_request;
    const result = filesystem.mkdir(io, input.path, input.recursive) catch |err| {
        try writeFailure(writer, @errorName(err), "Failed to create directory");
        return .ok;
    };

    try writeSuccess(writer, .{
        .path = result.path,
        .recursive = result.recursive,
    }, false);
    return .ok;
}

const FileListInput = struct {
    path: []const u8,
    offset: usize,
    max_entries: usize,
};

const ParsedFileWrite = struct {
    input: filesystem.WriteInput,
    owned_data: ?[]u8 = null,
};

const FileMkdirInput = struct {
    path: []const u8,
    recursive: bool,
};

fn parseRequiredPath(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?[]const u8 {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "path is required");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{"path"})) {
                try writeInvalidRequest(writer, "Invalid file arguments");
                break :blk null;
            }
            const path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                break :blk null;
            };
            if (path.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                break :blk null;
            }
            break :blk path;
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFileListInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?FileListInput {
    const value = arguments orelse return .{
        .path = ".",
        .offset = 0,
        .max_entries = filesystem.default_list_entries,
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "offset", "maxEntries" })) {
                try writeInvalidRequest(writer, "Invalid file_list arguments");
                break :blk null;
            }
            const path = if (object.get("path") != null)
                getString(object, "path") orelse {
                    try writeInvalidRequest(writer, "path must be a string");
                    break :blk null;
                }
            else
                ".";
            if (path.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                break :blk null;
            }
            const offset = try parseOptionalNonNegativeUsize(object, "offset", 0, writer) orelse break :blk null;
            const max_entries = try parseOptionalPositiveUsize(
                object,
                "maxEntries",
                filesystem.default_list_entries,
                filesystem.max_list_entries,
                writer,
            ) orelse break :blk null;
            break :blk .{ .path = path, .offset = offset, .max_entries = max_entries };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFileReadInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?filesystem.ReadInput {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "file_read requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "offset", "maxBytes" })) {
                try writeInvalidRequest(writer, "Invalid file_read arguments");
                break :blk null;
            }
            const path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                break :blk null;
            };
            if (path.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                break :blk null;
            }
            const offset = try parseOptionalNonNegativeU64(object, "offset", 0, writer) orelse break :blk null;
            const max_bytes = try parseOptionalPositiveUsize(
                object,
                "maxBytes",
                filesystem.default_read_bytes,
                filesystem.max_read_bytes,
                writer,
            ) orelse break :blk null;
            break :blk .{ .path = path, .offset = offset, .max_bytes = max_bytes };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFileSearchInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?filesystem.SearchInput {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "file_search requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "query", "glob", "maxResults" })) {
                try writeInvalidRequest(writer, "Invalid file_search arguments");
                break :blk null;
            }
            const path = if (object.get("path") != null)
                getString(object, "path") orelse {
                    try writeInvalidRequest(writer, "path must be a string");
                    break :blk null;
                }
            else
                ".";
            const query = getString(object, "query") orelse {
                try writeInvalidRequest(writer, "query must be a string");
                break :blk null;
            };
            const glob = if (object.get("glob") != null)
                getString(object, "glob") orelse {
                    try writeInvalidRequest(writer, "glob must be a string");
                    break :blk null;
                }
            else
                null;
            if (path.len == 0 or query.len == 0) {
                try writeInvalidRequest(writer, "path and query must not be empty");
                break :blk null;
            }
            if (glob) |pattern| {
                if (pattern.len == 0) {
                    try writeInvalidRequest(writer, "glob must not be empty");
                    break :blk null;
                }
            }
            const max_results = try parseOptionalPositiveUsize(
                object,
                "maxResults",
                filesystem.default_search_results,
                filesystem.max_search_results,
                writer,
            ) orelse break :blk null;
            break :blk .{
                .path = path,
                .query = query,
                .glob = glob,
                .max_results = max_results,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFilePatchInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?filesystem.PatchInput {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "file_patch requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "patch" })) {
                try writeInvalidRequest(writer, "Invalid file_patch arguments");
                break :blk null;
            }
            const path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                break :blk null;
            };
            const patch_text = getString(object, "patch") orelse {
                try writeInvalidRequest(writer, "patch must be a string");
                break :blk null;
            };
            if (path.len == 0 or patch_text.len == 0) {
                try writeInvalidRequest(writer, "path and patch must not be empty");
                break :blk null;
            }
            if (patch_text.len > filesystem.max_write_bytes) {
                try writeInvalidRequest(writer, "patch exceeds the maximum size");
                break :blk null;
            }
            break :blk .{ .path = path, .patch = patch_text };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFileWriteInput(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?ParsedFileWrite {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "file_write requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "data", "encoding", "append" })) {
                try writeInvalidRequest(writer, "Invalid file_write arguments");
                break :blk null;
            }
            const path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                break :blk null;
            };
            const data_text = getString(object, "data") orelse {
                try writeInvalidRequest(writer, "data must be a string");
                break :blk null;
            };
            const encoding = if (object.get("encoding") != null)
                getString(object, "encoding") orelse {
                    try writeInvalidRequest(writer, "encoding must be a string");
                    break :blk null;
                }
            else
                "utf8";
            const append = if (object.get("append")) |append_value| switch (append_value) {
                .bool => |flag| flag,
                else => {
                    try writeInvalidRequest(writer, "append must be a boolean");
                    break :blk null;
                },
            } else false;

            if (path.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                break :blk null;
            }

            if (std.mem.eql(u8, encoding, "utf8")) {
                if (data_text.len > filesystem.max_write_bytes) {
                    try writeInvalidRequest(writer, "decoded data exceeds the maximum write size");
                    break :blk null;
                }
                break :blk ParsedFileWrite{
                    .input = .{ .path = path, .data = data_text, .append = append },
                };
            }
            if (!std.mem.eql(u8, encoding, "base64")) {
                try writeInvalidRequest(writer, "encoding must be utf8 or base64");
                break :blk null;
            }

            const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(data_text) catch {
                try writeInvalidRequest(writer, "data is not valid base64");
                break :blk null;
            };
            if (decoded_size > filesystem.max_write_bytes) {
                try writeInvalidRequest(writer, "decoded data exceeds the maximum write size");
                break :blk null;
            }
            const decoded = try allocator.alloc(u8, decoded_size);
            std.base64.standard.Decoder.decode(decoded, data_text) catch {
                allocator.free(decoded);
                try writeInvalidRequest(writer, "data is not valid base64");
                break :blk null;
            };
            break :blk ParsedFileWrite{
                .input = .{ .path = path, .data = decoded, .append = append },
                .owned_data = decoded,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseFileMkdirInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?FileMkdirInput {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "file_mkdir requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "path", "recursive" })) {
                try writeInvalidRequest(writer, "Invalid file_mkdir arguments");
                break :blk null;
            }
            const path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                break :blk null;
            };
            if (path.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                break :blk null;
            }
            const recursive = if (object.get("recursive")) |recursive_value| switch (recursive_value) {
                .bool => |flag| flag,
                else => {
                    try writeInvalidRequest(writer, "recursive must be a boolean");
                    break :blk null;
                },
            } else true;
            break :blk .{ .path = path, .recursive = recursive };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseOptionalNonNegativeU64(
    object: anytype,
    name: []const u8,
    default_value: u64,
    writer: *std.Io.Writer,
) !?u64 {
    const value = object.get(name) orelse return default_value;
    return switch (value) {
        .integer => |number| if (number >= 0)
            @as(u64, @intCast(number))
        else blk: {
            try writeInvalidRequest(writer, "numeric argument is outside the allowed range");
            break :blk null;
        },
        else => blk: {
            try writeInvalidRequest(writer, "numeric argument must be an integer");
            break :blk null;
        },
    };
}

fn parseOptionalNonNegativeUsize(
    object: anytype,
    name: []const u8,
    default_value: usize,
    writer: *std.Io.Writer,
) !?usize {
    const value = try parseOptionalNonNegativeU64(object, name, @intCast(default_value), writer) orelse return null;
    if (value > std.math.maxInt(usize)) {
        try writeInvalidRequest(writer, "numeric argument is outside the allowed range");
        return null;
    }
    return @intCast(value);
}

fn parseOptionalPositiveUsize(
    object: anytype,
    name: []const u8,
    default_value: usize,
    max_value: usize,
    writer: *std.Io.Writer,
) !?usize {
    const value = try parseOptionalNonNegativeUsize(object, name, default_value, writer) orelse return null;
    if (value == 0 or value > max_value) {
        try writeInvalidRequest(writer, "numeric argument is outside the allowed range");
        return null;
    }
    return value;
}

fn hasOnlyFields(object: anytype, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn getString(object: anytype, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn writeSuccess(
    writer: *std.Io.Writer,
    result: anytype,
    is_error: bool,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = true,
        .result = result,
        .isError = is_error,
    }, .{ .emit_null_optional_fields = false })});
}

fn writeFailure(
    writer: *std.Io.Writer,
    code: []const u8,
    message: []const u8,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .isError = true,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{})});
}

fn writeInvalidRequest(
    writer: *std.Io.Writer,
    message: []const u8,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .invalidRequest = true,
        .isError = true,
        .@"error" = .{
            .code = "InvalidRequest",
            .message = message,
        },
    }, .{})});
}
