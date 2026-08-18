const std = @import("std");
const transport = @import("transport.zig");
const control = @import("../control/state.zig");

pub const binary_magic = transport.binary_magic;
pub const binary_header_size = transport.binary_header_size;

const Sha256 = std.crypto.hash.sha2.Sha256;

const SourceState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *transport.DeviceTransport,
    id: [16]u8,
    id_text: [32]u8,
    path: []u8,
    size: u64,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn deinit(self: *SourceState) void {
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

const TargetState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: [16]u8,
    id_text: [32]u8,
    final_path: []u8,
    part_path: []u8,
    overwrite: bool,
    file: std.Io.File,
    file_open: bool = true,
    hasher: Sha256 = Sha256.init(.{}),
    bytes_written: u64 = 0,
    next_sequence: u64 = 0,

    fn deinit(self: *TargetState, delete_part: bool) void {
        if (self.file_open) {
            self.file.close(self.io);
            self.file_open = false;
        }
        if (delete_part) {
            std.Io.Dir.cwd().deleteFile(self.io, self.part_path) catch {};
        }
        self.allocator.free(self.final_path);
        self.allocator.free(self.part_path);
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *transport.DeviceTransport,
    mutex: std.Io.Mutex = .init,
    source: ?*SourceState = null,
    target: ?*TargetState = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, device_transport: *transport.DeviceTransport) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = device_transport,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        const source = self.source;
        self.source = null;
        if (source) |state| state.cancelled.store(true, .release);
        const target = self.target;
        self.target = null;
        self.mutex.unlock(self.io);

        if (source) |state| {
            if (state.thread) |thread| thread.join();
            state.deinit();
        }
        if (target) |state| state.deinit(true);
    }

    /// Handle one transfer control message. Returns false when the message is
    /// not part of the transfer protocol and should be handled by the normal
    /// ShellCore call/ping dispatcher.
    pub fn handleText(self: *Manager, bytes: []const u8) !bool {
        const Header = struct { type: []const u8 };
        const header = std.json.parseFromSlice(Header, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch return false;
        defer header.deinit();
        if (!std.mem.startsWith(u8, header.value.type, "transfer_")) return false;

        if (std.mem.eql(u8, header.value.type, "transfer_source_start")) {
            const Message = struct {
                type: []const u8,
                transferId: []const u8,
                path: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.prepareSource(parsed.value.transferId, parsed.value.path) catch |err| {
                try self.sendFailure(parsed.value.transferId, "source", err);
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "transfer_target_start")) {
            const Message = struct {
                type: []const u8,
                transferId: []const u8,
                path: []const u8,
                overwrite: bool = false,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.prepareTarget(parsed.value.transferId, parsed.value.path, parsed.value.overwrite) catch |err| {
                try self.sendFailure(parsed.value.transferId, "target", err);
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "transfer_send")) {
            const Message = struct { type: []const u8, transferId: []const u8 };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.startSource(parsed.value.transferId) catch |err| {
                try self.sendFailure(parsed.value.transferId, "source", err);
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "transfer_commit")) {
            const Message = struct {
                type: []const u8,
                transferId: []const u8,
                size: u64,
                sha256: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.commitTarget(parsed.value.transferId, parsed.value.size, parsed.value.sha256) catch |err| {
                self.dropTarget(parsed.value.transferId, true);
                try self.sendFailure(parsed.value.transferId, "target", err);
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "transfer_cancel")) {
            const Message = struct { type: []const u8, transferId: []const u8 };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.cancel(parsed.value.transferId);
            return true;
        }

        return error.UnsupportedTransferMessage;
    }

    pub fn handleBinary(self: *Manager, frame: []const u8) !bool {
        if (frame.len < binary_header_size) return error.InvalidTransferFrame;
        if (!std.mem.eql(u8, frame[0..binary_magic.len], binary_magic)) return error.InvalidTransferFrame;

        var id: [16]u8 = undefined;
        @memcpy(&id, frame[binary_magic.len .. binary_magic.len + id.len]);
        const sequence_offset = binary_magic.len + id.len;
        const sequence = std.mem.readInt(u64, frame[sequence_offset .. sequence_offset + 8], .big);
        const payload = frame[binary_header_size..];

        self.mutex.lockUncancelable(self.io);
        const state = self.target orelse {
            self.mutex.unlock(self.io);
            return false;
        };
        if (!std.mem.eql(u8, &state.id, &id)) {
            self.mutex.unlock(self.io);
            return false;
        }
        if (sequence != state.next_sequence) {
            const id_text = state.id_text;
            self.mutex.unlock(self.io);
            self.dropTarget(&id_text, true);
            try self.sendFailure(&id_text, "target", error.TransferSequenceMismatch);
            return false;
        }

        const offset = state.bytes_written;
        state.file.writePositionalAll(self.io, payload, offset) catch |err| {
            const id_text = state.id_text;
            self.mutex.unlock(self.io);
            self.dropTarget(&id_text, true);
            try self.sendFailure(&id_text, "target", err);
            return false;
        };
        state.hasher.update(payload);
        state.bytes_written += @intCast(payload.len);
        state.next_sequence += 1;
        self.mutex.unlock(self.io);
        return true;
    }

    fn prepareSource(self: *Manager, id_text: []const u8, path: []const u8) !void {
        if (path.len == 0) return error.EmptyTransferPath;
        const id = try parseTransferId(id_text);
        try self.reapFinishedSource();

        const info = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = true });
        if (info.kind != .file) return error.TransferSourceNotFile;

        const state = try self.allocator.create(SourceState);
        errdefer self.allocator.destroy(state);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        state.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .transport = self.transport,
            .id = id,
            .id_text = std.fmt.bytesToHex(id, .lower),
            .path = owned_path,
            .size = info.size,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.source != null) {
            self.mutex.unlock(self.io);
            state.deinit();
            return error.TransferSourceBusy;
        }
        self.source = state;
        self.mutex.unlock(self.io);

        try self.sendJson(.{
            .type = "transfer_source_ready",
            .transferId = &state.id_text,
            .size = state.size,
        });
    }

    fn prepareTarget(self: *Manager, id_text: []const u8, path: []const u8, overwrite: bool) !void {
        try control.requireAgent(self.io);
        if (path.len == 0) return error.EmptyTransferPath;
        const id = try parseTransferId(id_text);

        self.mutex.lockUncancelable(self.io);
        const busy = self.target != null;
        self.mutex.unlock(self.io);
        if (busy) return error.TransferTargetBusy;

        if (!overwrite) {
            if (std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false })) |_| {
                return error.TransferTargetExists;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        const final_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(final_path);
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}.zshell-part", .{path});
        errdefer self.allocator.free(part_path);

        std.Io.Dir.cwd().deleteFile(self.io, part_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var file = try std.Io.Dir.cwd().createFile(self.io, part_path, .{ .read = true, .truncate = true });
        errdefer file.close(self.io);

        const state = try self.allocator.create(TargetState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .id = id,
            .id_text = std.fmt.bytesToHex(id, .lower),
            .final_path = final_path,
            .part_path = part_path,
            .overwrite = overwrite,
            .file = file,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.target != null) {
            self.mutex.unlock(self.io);
            state.deinit(true);
            return error.TransferTargetBusy;
        }
        self.target = state;
        self.mutex.unlock(self.io);

        try self.sendJson(.{
            .type = "transfer_target_ready",
            .transferId = &state.id_text,
        });
    }

    fn startSource(self: *Manager, id_text: []const u8) !void {
        const id = try parseTransferId(id_text);
        try self.reapFinishedSource();

        self.mutex.lockUncancelable(self.io);
        const state = self.source orelse {
            self.mutex.unlock(self.io);
            return error.TransferSourceNotPrepared;
        };
        if (!std.mem.eql(u8, &state.id, &id)) {
            self.mutex.unlock(self.io);
            return error.TransferIdMismatch;
        }
        if (state.thread != null) {
            self.mutex.unlock(self.io);
            return error.TransferAlreadyStarted;
        }

        const thread = std.Thread.spawn(.{}, sourceWorkerMain, .{state}) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        state.thread = thread;
        self.mutex.unlock(self.io);
    }

    fn commitTarget(self: *Manager, id_text: []const u8, expected_size: u64, expected_sha: []const u8) !void {
        const id = try parseTransferId(id_text);
        if (expected_sha.len != Sha256.digest_length * 2) return error.InvalidTransferHash;

        self.mutex.lockUncancelable(self.io);
        const state = self.target orelse {
            self.mutex.unlock(self.io);
            return error.TransferTargetNotPrepared;
        };
        if (!std.mem.eql(u8, &state.id, &id)) {
            self.mutex.unlock(self.io);
            return error.TransferIdMismatch;
        }
        if (state.bytes_written != expected_size) {
            self.mutex.unlock(self.io);
            return error.TransferSizeMismatch;
        }

        var digest: [Sha256.digest_length]u8 = undefined;
        state.hasher.final(&digest);
        const actual_sha = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&actual_sha, expected_sha)) {
            self.mutex.unlock(self.io);
            return error.TransferHashMismatch;
        }

        if (state.file_open) {
            state.file.close(self.io);
            state.file_open = false;
        }

        if (!state.overwrite) {
            if (std.Io.Dir.cwd().statFile(self.io, state.final_path, .{ .follow_symlinks = false })) |_| {
                self.mutex.unlock(self.io);
                return error.TransferTargetExists;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    self.mutex.unlock(self.io);
                    return err;
                },
            }
        }

        std.Io.Dir.cwd().rename(state.part_path, std.Io.Dir.cwd(), state.final_path, self.io) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.target = null;
        self.mutex.unlock(self.io);
        defer state.deinit(false);

        try self.sendJson(.{
            .type = "transfer_target_finish",
            .transferId = &state.id_text,
            .size = state.bytes_written,
            .sha256 = &actual_sha,
        });
    }

    fn cancel(self: *Manager, id_text: []const u8) void {
        const id = parseTransferId(id_text) catch return;

        self.mutex.lockUncancelable(self.io);
        var source_to_free: ?*SourceState = null;
        if (self.source) |state| {
            if (std.mem.eql(u8, &state.id, &id)) {
                self.source = null;
                state.cancelled.store(true, .release);
                source_to_free = state;
            }
        }
        var target: ?*TargetState = null;
        if (self.target) |state| {
            if (std.mem.eql(u8, &state.id, &id)) {
                target = state;
                self.target = null;
            }
        }
        self.mutex.unlock(self.io);

        if (source_to_free) |state| {
            if (state.thread) |thread| thread.join();
            state.deinit();
        }
        if (target) |state| state.deinit(true);
    }

    fn dropTarget(self: *Manager, id_text: []const u8, delete_part: bool) void {
        const id = parseTransferId(id_text) catch return;
        self.mutex.lockUncancelable(self.io);
        var state: ?*TargetState = null;
        if (self.target) |candidate| {
            if (std.mem.eql(u8, &candidate.id, &id)) {
                state = candidate;
                self.target = null;
            }
        }
        self.mutex.unlock(self.io);
        if (state) |target| target.deinit(delete_part);
    }

    fn reapFinishedSource(self: *Manager) !void {
        self.mutex.lockUncancelable(self.io);
        const state = self.source orelse {
            self.mutex.unlock(self.io);
            return;
        };
        if (!state.done.load(.acquire)) {
            self.mutex.unlock(self.io);
            return;
        }
        self.source = null;
        self.mutex.unlock(self.io);

        if (state.thread) |thread| thread.join();
        state.deinit();
    }

    fn sendFailure(self: *Manager, id_text: []const u8, role: []const u8, err: anyerror) !void {
        try self.sendJson(.{
            .type = "transfer_failed",
            .transferId = id_text,
            .role = role,
            .@"error" = @errorName(err),
        });
    }

    fn sendJson(self: *Manager, value: anytype) !void {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(value, .{})});
        try self.transport.writeText(payload.written());
    }
};

fn sourceWorkerMain(state: *SourceState) void {
    sourceWorker(state) catch |err| {
        sendSourceFailure(state, err) catch {};
    };
    state.done.store(true, .release);
}

fn sourceWorker(state: *SourceState) !void {
    var file = try std.Io.Dir.cwd().openFile(state.io, state.path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(state.io);

    var buffer = try state.allocator.alloc(u8, state.transport.transferChunkSize());
    defer state.allocator.free(buffer);
    var hasher = Sha256.init(.{});
    var offset: u64 = 0;
    var sequence: u64 = 0;

    while (offset < state.size) {
        if (state.cancelled.load(.acquire)) {
            try sendSourceCancelled(state);
            return;
        }

        const remaining = state.size - offset;
        const wanted: usize = @intCast(@min(remaining, @as(u64, state.transport.transferChunkSize())));
        const count = try file.readPositionalAll(state.io, buffer[0..wanted], offset);
        if (count != wanted) return error.TransferSourceChanged;
        const chunk = buffer[0..count];
        hasher.update(chunk);

        try state.transport.sendTransferChunk(state.id, sequence, chunk);

        offset += @intCast(count);
        sequence += 1;
    }

    if (state.cancelled.load(.acquire)) {
        try sendSourceCancelled(state);
        return;
    }

    const final_info = try file.stat(state.io);
    if (final_info.size != state.size) return error.TransferSourceChanged;

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try sendSourceJson(state, .{
        .type = "transfer_source_finish",
        .transferId = &state.id_text,
        .size = offset,
        .sha256 = &digest_hex,
    });
}

fn sendSourceCancelled(state: *SourceState) !void {
    try sendSourceJson(state, .{
        .type = "transfer_source_cancelled",
        .transferId = &state.id_text,
    });
}

fn sendSourceFailure(state: *SourceState, err: anyerror) !void {
    try sendSourceJson(state, .{
        .type = "transfer_failed",
        .transferId = &state.id_text,
        .role = "source",
        .@"error" = @errorName(err),
    });
}

fn sendSourceJson(state: *SourceState, value: anytype) !void {
    var payload: std.Io.Writer.Allocating = .init(state.allocator);
    defer payload.deinit();
    try payload.writer.print("{f}", .{std.json.fmt(value, .{})});
    try state.transport.writeText(payload.written());
}

pub fn parseTransferId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidTransferId;
    var result: [16]u8 = undefined;
    for (0..result.len) |index| {
        const high = try hexNibble(text[index * 2]);
        const low = try hexNibble(text[index * 2 + 1]);
        result[index] = (high << 4) | low;
    }
    return result;
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidTransferId,
    };
}

test "transfer id round trip" {
    const text = "00112233445566778899aabbccddeeff";
    const id = try parseTransferId(text);
    const encoded = std.fmt.bytesToHex(id, .lower);
    try std.testing.expectEqualStrings(text, &encoded);
}
