const std = @import("std");
const control = @import("../control/state.zig");
const transfer = @import("transfer.zig");
const transport = @import("transport.zig");

const max_chunk_size: usize = 32 * 1024;

const Role = enum { source, target };

const ConnectionState = struct {
    manager: *Manager,
    role: Role,
    forward_id: [16]u8,
    forward_id_text: [32]u8,
    id: [16]u8,
    id_text: [32]u8,
    stream: std.Io.net.Stream,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,

    fn close(self: *ConnectionState) void {
        if (!self.closed.swap(true, .acq_rel)) {
            self.stream.close(self.manager.io);
        }
    }
};

const ListenerState = struct {
    manager: *Manager,
    id: [16]u8,
    id_text: [32]u8,
    server: std.Io.net.Server,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn stop(self: *ListenerState) void {
        if (!self.stopped.swap(true, .acq_rel)) {
            self.server.socket.close(self.manager.io);
        }
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *transport.DeviceTransport,
    mutex: std.Io.Mutex = .init,
    listener: ?*ListenerState = null,
    connections: std.StringHashMapUnmanaged(*ConnectionState) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, device_transport: *transport.DeviceTransport) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = device_transport,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        const listener = self.listener;
        self.listener = null;
        if (listener) |state| state.stop();

        var it = self.connections.iterator();
        while (it.next()) |entry| entry.value_ptr.*.close();
        self.mutex.unlock(self.io);

        if (listener) |state| {
            if (state.thread) |thread| thread.join();
            self.allocator.destroy(state);
        }

        var free_it = self.connections.iterator();
        while (free_it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| thread.join();
            self.allocator.destroy(state);
        }
        self.connections.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleText(self: *Manager, bytes: []const u8) !bool {
        const Header = struct { type: []const u8 };
        const header = std.json.parseFromSlice(Header, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch return false;
        defer header.deinit();
        if (!std.mem.startsWith(u8, header.value.type, "forward_")) return false;

        if (std.mem.eql(u8, header.value.type, "forward_source_start")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                listenHost: []const u8,
                listenPort: u16,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.startListener(parsed.value.forwardId, parsed.value.listenHost, parsed.value.listenPort) catch |err| {
                try self.sendJson(.{
                    .type = "forward_failed",
                    .forwardId = parsed.value.forwardId,
                    .@"error" = @errorName(err),
                });
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_target_connect")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                connectionId: []const u8,
                targetHost: []const u8,
                targetPort: u16,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.connectTarget(parsed.value.forwardId, parsed.value.connectionId, parsed.value.targetHost, parsed.value.targetPort) catch |err| {
                try self.sendJson(.{
                    .type = "forward_connection_failed",
                    .forwardId = parsed.value.forwardId,
                    .connectionId = parsed.value.connectionId,
                    .@"error" = @errorName(err),
                });
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_connected")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                connectionId: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            try self.startReader(parsed.value.forwardId, parsed.value.connectionId);
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_data")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                connectionId: []const u8,
                data: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            try self.writeData(parsed.value.forwardId, parsed.value.connectionId, parsed.value.data);
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_connection_close") or
            std.mem.eql(u8, header.value.type, "forward_connection_failed"))
        {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                connectionId: []const u8,
                @"error": ?[]const u8 = null,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.closeConnection(parsed.value.forwardId, parsed.value.connectionId);
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_stop")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.stopForward(parsed.value.forwardId);
            return true;
        }

        return error.UnsupportedForwardMessage;
    }

    fn startListener(self: *Manager, id_text: []const u8, host: []const u8, port: u16) !void {
        try control.requireAgent(self.io);
        const id = try transfer.parseTransferId(id_text);
        const address = try std.Io.net.IpAddress.parse(host, port);
        var server = try address.listen(self.io, .{ .reuse_address = true });
        errdefer server.deinit(self.io);

        const state = try self.allocator.create(ListenerState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .manager = self,
            .id = id,
            .id_text = std.fmt.bytesToHex(id, .lower),
            .server = server,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.listener != null) {
            self.mutex.unlock(self.io);
            state.server.deinit(self.io);
            self.allocator.destroy(state);
            return error.ForwardListenerBusy;
        }
        self.listener = state;
        self.mutex.unlock(self.io);

        state.thread = std.Thread.spawn(.{}, listenerWorkerMain, .{state}) catch |err| {
            self.mutex.lockUncancelable(self.io);
            if (self.listener == state) self.listener = null;
            self.mutex.unlock(self.io);
            state.server.deinit(self.io);
            self.allocator.destroy(state);
            return err;
        };

        try self.sendJson(.{
            .type = "forward_source_ready",
            .forwardId = &state.id_text,
            .listenHost = host,
            .listenPort = state.server.socket.address.getPort(),
        });
    }

    fn connectTarget(self: *Manager, forward_id_text: []const u8, conn_id_text: []const u8, host: []const u8, port: u16) !void {
        try control.requireAgent(self.io);
        const forward_id = try transfer.parseTransferId(forward_id_text);
        const conn_id = try transfer.parseTransferId(conn_id_text);
        const host_name = try std.Io.net.HostName.init(host);
        const stream = try host_name.connect(self.io, port, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = .none,
        });
        errdefer stream.close(self.io);

        const state = try self.createConnection(.target, forward_id, conn_id, stream);
        try self.sendJson(.{
            .type = "forward_connected",
            .forwardId = &state.forward_id_text,
            .connectionId = &state.id_text,
        });
        try self.startConnectionReader(state);
    }

    fn createConnection(self: *Manager, role: Role, forward_id: [16]u8, conn_id: [16]u8, stream: std.Io.net.Stream) !*ConnectionState {
        const state = try self.allocator.create(ConnectionState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .manager = self,
            .role = role,
            .forward_id = forward_id,
            .forward_id_text = std.fmt.bytesToHex(forward_id, .lower),
            .id = conn_id,
            .id_text = std.fmt.bytesToHex(conn_id, .lower),
            .stream = stream,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.connections.get(&state.id_text) != null) {
            self.allocator.destroy(state);
            return error.DuplicateForwardConnection;
        }
        try self.connections.put(self.allocator, &state.id_text, state);
        return state;
    }

    fn startReader(self: *Manager, forward_id_text: []const u8, conn_id_text: []const u8) !void {
        const forward_id = try transfer.parseTransferId(forward_id_text);
        const conn_id = try transfer.parseTransferId(conn_id_text);
        const conn_id_hex = std.fmt.bytesToHex(conn_id, .lower);

        self.mutex.lockUncancelable(self.io);
        const state = self.connections.get(&conn_id_hex) orelse {
            self.mutex.unlock(self.io);
            return error.ForwardConnectionNotFound;
        };
        if (!std.mem.eql(u8, &state.forward_id, &forward_id)) {
            self.mutex.unlock(self.io);
            return error.ForwardIdMismatch;
        }
        self.mutex.unlock(self.io);
        try self.startConnectionReader(state);
    }

    fn startConnectionReader(self: *Manager, state: *ConnectionState) !void {
        _ = self;
        if (state.reader_started.swap(true, .acq_rel)) return;
        state.thread = try std.Thread.spawn(.{}, connectionReaderMain, .{state});
    }

    fn writeData(self: *Manager, forward_id_text: []const u8, conn_id_text: []const u8, encoded: []const u8) !void {
        const forward_id = try transfer.parseTransferId(forward_id_text);
        const conn_id = try transfer.parseTransferId(conn_id_text);
        const conn_id_hex = std.fmt.bytesToHex(conn_id, .lower);

        self.mutex.lockUncancelable(self.io);
        const state = self.connections.get(&conn_id_hex) orelse {
            self.mutex.unlock(self.io);
            return error.ForwardConnectionNotFound;
        };
        if (!std.mem.eql(u8, &state.forward_id, &forward_id) or state.closed.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.ForwardConnectionClosed;
        }
        self.mutex.unlock(self.io);

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        if (decoded_len > max_chunk_size) return error.ForwardChunkTooLarge;
        const buffer = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(buffer);
        try std.base64.standard.Decoder.decode(buffer, encoded);

        state.write_mutex.lockUncancelable(self.io);
        defer state.write_mutex.unlock(self.io);
        if (state.closed.load(.acquire)) return error.ForwardConnectionClosed;
        var writer = state.stream.writer(self.io, &.{});
        try writer.interface.writeAll(buffer);
        try writer.interface.flush();
    }

    fn closeConnection(self: *Manager, forward_id_text: []const u8, conn_id_text: []const u8) void {
        const forward_id = transfer.parseTransferId(forward_id_text) catch return;
        const conn_id = transfer.parseTransferId(conn_id_text) catch return;
        const conn_id_hex = std.fmt.bytesToHex(conn_id, .lower);

        self.mutex.lockUncancelable(self.io);
        const state = self.connections.get(&conn_id_hex);
        self.mutex.unlock(self.io);
        if (state) |conn| {
            if (std.mem.eql(u8, &conn.forward_id, &forward_id)) conn.close();
        }
    }

    fn stopForward(self: *Manager, id_text: []const u8) void {
        const id = transfer.parseTransferId(id_text) catch return;

        self.mutex.lockUncancelable(self.io);
        const listener = self.listener;
        if (listener) |state| {
            if (std.mem.eql(u8, &state.id, &id)) {
                self.listener = null;
                state.stop();
            }
        }
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (std.mem.eql(u8, &state.forward_id, &id)) state.close();
        }
        self.mutex.unlock(self.io);

        if (listener) |state| {
            if (std.mem.eql(u8, &state.id, &id)) {
                if (state.thread) |thread| thread.join();
                self.allocator.destroy(state);
            }
        }
    }

    fn sendJson(self: *Manager, value: anytype) !void {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(value, .{})});
        try self.transport.writeText(payload.written());
    }
};

fn listenerWorkerMain(state: *ListenerState) void {
    listenerWorker(state) catch |err| {
        if (!state.stopped.load(.acquire)) {
            state.manager.sendJson(.{
                .type = "forward_failed",
                .forwardId = &state.id_text,
                .@"error" = @errorName(err),
            }) catch {};
        }
    };
}

fn listenerWorker(state: *ListenerState) !void {
    while (!state.stopped.load(.acquire)) {
        const stream = state.server.accept(state.manager.io) catch |err| {
            if (state.stopped.load(.acquire)) return;
            return err;
        };
        errdefer stream.close(state.manager.io);

        var conn_id: [16]u8 = undefined;
        state.manager.io.random(&conn_id);
        const conn = try state.manager.createConnection(.source, state.id, conn_id, stream);
        try state.manager.sendJson(.{
            .type = "forward_open",
            .forwardId = &state.id_text,
            .connectionId = &conn.id_text,
        });
    }
}

fn connectionReaderMain(state: *ConnectionState) void {
    connectionReader(state) catch {};
    state.manager.sendJson(.{
        .type = "forward_connection_close",
        .forwardId = &state.forward_id_text,
        .connectionId = &state.id_text,
    }) catch {};
    state.close();
}

fn connectionReader(state: *ConnectionState) !void {
    var reader_buffer: [8192]u8 = undefined;
    var data: [max_chunk_size]u8 = undefined;
    var reader = state.stream.reader(state.manager.io, &reader_buffer);

    while (!state.closed.load(.acquire)) {
        var slices = [_][]u8{&data};
        const count = reader.interface.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return,
        };
        if (count == 0) continue;

        const encoded_len = std.base64.standard.Encoder.calcSize(count);
        const encoded = try state.manager.allocator.alloc(u8, encoded_len);
        defer state.manager.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, data[0..count]);

        try state.manager.sendJson(.{
            .type = "forward_data",
            .forwardId = &state.forward_id_text,
            .connectionId = &state.id_text,
            .data = encoded,
        });
    }
}
