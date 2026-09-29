const std = @import("std");
const builtin = @import("builtin");
const control = @import("../control/state.zig");
const mesh = @import("mesh.zig");
const transfer = @import("transfer.zig");
const transport = @import("transport.zig");

const max_relay_chunk_size: usize = 32 * 1024;
const direct_chunk_size: usize = 1000;
const direct_window: usize = 64;
const direct_ack_bitmap_bytes: usize = direct_window / 8;
const direct_probe_rounds: usize = 100;
const direct_probe_interval_ms: u64 = 50;
const direct_retransmit_ns: i96 = 200 * std.time.ns_per_ms;
const direct_stall_ns: i96 = 5 * std.time.ns_per_s;
const direct_send_budget: usize = 8;
const direct_pacing_ns: i96 = std.time.ns_per_ms;
const max_peer_candidates: usize = 4;

const Role = enum { source, target };
const ForwardMode = enum { pending, direct, relay };

const CandidateSet = struct {
    items: [max_peer_candidates]?std.Io.net.IpAddress = @splat(null),
    count: usize = 0,
};

const ForwardState = struct {
    manager: *Manager,
    id: [16]u8,
    id_text: [32]u8,
    mode: ForwardMode,
    direct_requested: bool,
    peer_candidates: [max_peer_candidates]?std.Io.net.IpAddress = @splat(null),
    direct_peer: ?std.Io.net.IpAddress = null,
    ready_sent: bool = false,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

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

    tx_mutex: std.Io.Mutex = .init,
    tx_base: u64 = 0,
    tx_next: u64 = 0,
    tx_acked: [direct_window]bool = @splat(false),

    rx_mutex: std.Io.Mutex = .init,
    rx_base: u64 = 0,
    rx_received: [direct_window]bool = @splat(false),
    rx_len: [direct_window]u16 = @splat(0),
    rx_payload: [direct_window][direct_chunk_size]u8 = undefined,

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
        if (self.stopped.swap(true, .acq_rel)) return;

        // Wake a blocking accept before closing the listening socket. Some
        // threaded I/O backends do not reliably cancel accept from close().
        var wake_address = self.server.socket.address;
        switch (wake_address) {
            .ip4 => |*ip4| {
                if (std.mem.eql(u8, &ip4.bytes, &[_]u8{ 0, 0, 0, 0 })) {
                    ip4.bytes = .{ 127, 0, 0, 1 };
                }
            },
            .ip6 => {},
        }
        if (wake_address.connect(self.manager.io, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = .none,
        })) |stream| {
            stream.close(self.manager.io);
        } else |_| {}

        self.server.socket.close(self.manager.io);
    }
};

const ModePeer = struct {
    mode: ForwardMode,
    peer: ?std.Io.net.IpAddress,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *transport.DeviceTransport,
    mesh_manager: ?*mesh.Manager,
    mutex: std.Io.Mutex = .init,
    listener: ?*ListenerState = null,
    forwards: std.StringHashMapUnmanaged(*ForwardState) = .empty,
    connections: std.StringHashMapUnmanaged(*ConnectionState) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        device_transport: *transport.DeviceTransport,
        mesh_manager: ?*mesh.Manager,
    ) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = device_transport,
            .mesh_manager = mesh_manager,
        };
    }

    pub fn attachMeshHandler(self: *Manager) void {
        const manager = self.mesh_manager orelse return;
        manager.setHandler(.forward, .{
            .context = @ptrCast(self),
            .on_packet = meshPacket,
        });
    }

    pub fn detachMeshHandler(self: *Manager) void {
        const manager = self.mesh_manager orelse return;
        manager.setHandler(.forward, null);
    }

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        const listener = self.listener;
        self.listener = null;
        if (listener) |state| state.stop();

        var forward_it = self.forwards.iterator();
        while (forward_it.next()) |entry| entry.value_ptr.*.stopped.store(true, .release);

        var conn_it = self.connections.iterator();
        while (conn_it.next()) |entry| entry.value_ptr.*.close();
        self.mutex.unlock(self.io);

        if (listener) |state| {
            if (state.thread) |thread| thread.join();
            self.allocator.destroy(state);
        }

        var free_forward_it = self.forwards.iterator();
        while (free_forward_it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| thread.join();
            self.allocator.destroy(state);
        }
        self.forwards.deinit(self.allocator);

        var free_conn_it = self.connections.iterator();
        while (free_conn_it.next()) |entry| {
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

        if (std.mem.eql(u8, header.value.type, "forward_target_prepare")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                direct: bool = false,
                peerCandidate: []const u8 = "",
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            _ = try self.ensureForward(parsed.value.forwardId, parsed.value.direct, parsed.value.peerCandidate);
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_source_start")) {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
                listenHost: []const u8,
                listenPort: u16,
                direct: bool = false,
                peerCandidate: []const u8 = "",
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            _ = self.ensureForward(parsed.value.forwardId, parsed.value.direct, parsed.value.peerCandidate) catch |err| {
                try self.sendJson(.{
                    .type = "forward_failed",
                    .forwardId = parsed.value.forwardId,
                    .@"error" = @errorName(err),
                });
                return true;
            };
            self.startListener(parsed.value.forwardId, parsed.value.listenHost, parsed.value.listenPort) catch |err| {
                try self.sendJson(.{
                    .type = "forward_failed",
                    .forwardId = parsed.value.forwardId,
                    .@"error" = @errorName(err),
                });
            };
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "forward_direct_start") or
            std.mem.eql(u8, header.value.type, "forward_relay_start"))
        {
            const Message = struct {
                type: []const u8,
                forwardId: []const u8,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            const mode: ForwardMode = if (std.mem.eql(u8, header.value.type, "forward_direct_start")) .direct else .relay;
            self.setForwardMode(parsed.value.forwardId, mode);
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
            _ = self.ensureForward(parsed.value.forwardId, false, "") catch {};
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
            try self.writeRelayData(parsed.value.forwardId, parsed.value.connectionId, parsed.value.data);
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

    fn ensureForward(self: *Manager, id_text: []const u8, direct: bool, peer_candidate: []const u8) !*ForwardState {
        const id = try transfer.parseTransferId(id_text);
        const id_hex = std.fmt.bytesToHex(id, .lower);

        self.mutex.lockUncancelable(self.io);
        if (self.forwards.get(&id_hex)) |existing| {
            self.mutex.unlock(self.io);
            return existing;
        }
        self.mutex.unlock(self.io);

        var candidates: CandidateSet = .{};
        if (direct) candidates = try parseCandidates(peer_candidate);
        const can_direct = direct and self.mesh_manager != null and candidates.count != 0;

        const state = try self.allocator.create(ForwardState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .manager = self,
            .id = id,
            .id_text = id_hex,
            .mode = if (can_direct) .pending else .relay,
            .direct_requested = can_direct,
            .peer_candidates = candidates.items,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.forwards.get(&state.id_text)) |existing| {
            self.mutex.unlock(self.io);
            self.allocator.destroy(state);
            return existing;
        }
        try self.forwards.put(self.allocator, &state.id_text, state);
        self.mutex.unlock(self.io);

        if (can_direct) {
            state.thread = std.Thread.spawn(.{}, forwardProbeMain, .{state}) catch |err| {
                self.mutex.lockUncancelable(self.io);
                _ = self.forwards.remove(&state.id_text);
                self.mutex.unlock(self.io);
                self.allocator.destroy(state);
                return err;
            };
        }
        return state;
    }

    fn setForwardMode(self: *Manager, id_text: []const u8, mode: ForwardMode) void {
        const id = transfer.parseTransferId(id_text) catch return;
        const id_hex = std.fmt.bytesToHex(id, .lower);
        self.mutex.lockUncancelable(self.io);
        if (self.forwards.get(&id_hex)) |state| {
            state.mode = mode;
        }
        self.mutex.unlock(self.io);
    }

    fn forwardModePeer(self: *Manager, forward_id: [16]u8) ModePeer {
        const id_hex = std.fmt.bytesToHex(forward_id, .lower);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.forwards.get(&id_hex) orelse return .{ .mode = .relay, .peer = null };
        return .{ .mode = state.mode, .peer = state.direct_peer };
    }

    fn markForwardPeer(self: *Manager, id: [16]u8, from: std.Io.net.IpAddress) bool {
        const id_hex = std.fmt.bytesToHex(id, .lower);
        var notify = false;
        self.mutex.lockUncancelable(self.io);
        if (self.forwards.get(&id_hex)) |state| {
            if (state.direct_requested and state.mode == .pending) {
                if (state.direct_peer == null) state.direct_peer = from;
                if (!state.ready_sent) {
                    state.ready_sent = true;
                    notify = true;
                }
            }
        }
        self.mutex.unlock(self.io);
        if (notify) {
            self.sendJson(.{
                .type = "forward_direct_ready",
                .forwardId = &id_hex,
            }) catch {};
        }
        return notify;
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

    fn writeRelayData(self: *Manager, forward_id_text: []const u8, conn_id_text: []const u8, encoded: []const u8) !void {
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
        if (decoded_len > max_relay_chunk_size) return error.ForwardChunkTooLarge;
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
        const id_hex = std.fmt.bytesToHex(id, .lower);

        var forward_state: ?*ForwardState = null;
        self.mutex.lockUncancelable(self.io);
        const listener = self.listener;
        if (listener) |state| {
            if (std.mem.eql(u8, &state.id, &id)) {
                self.listener = null;
                state.stop();
            }
        }
        if (self.forwards.get(&id_hex)) |state| {
            forward_state = state;
            _ = self.forwards.remove(&id_hex);
            state.stopped.store(true, .release);
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
        if (forward_state) |state| {
            if (state.thread) |thread| thread.join();
            self.allocator.destroy(state);
        }
    }

    fn probeForward(self: *Manager, state: *ForwardState) void {
        const mesh_manager = self.mesh_manager orelse return;
        for (state.peer_candidates) |candidate| {
            const destination = candidate orelse continue;
            mesh_manager.send(destination, .forward_probe, state.id, 0, &.{}) catch {};
        }
    }

    fn handleMeshPacket(
        self: *Manager,
        packet_type: mesh.PacketType,
        id: [16]u8,
        sequence: u64,
        payload: []const u8,
        from: std.Io.net.IpAddress,
    ) void {
        const mesh_manager = self.mesh_manager orelse return;
        switch (packet_type) {
            .forward_probe => {
                _ = self.markForwardPeer(id, from);
                const id_hex = std.fmt.bytesToHex(id, .lower);
                self.mutex.lockUncancelable(self.io);
                const matched = self.forwards.get(&id_hex) != null;
                self.mutex.unlock(self.io);
                if (matched) mesh_manager.send(from, .forward_probe_ack, id, 0, &.{}) catch {};
            },
            .forward_probe_ack => {
                _ = self.markForwardPeer(id, from);
            },
            .forward_ack => self.handleDirectAck(id, sequence, payload),
            .forward_data => self.handleDirectData(id, sequence, payload, from),
            else => {},
        }
    }

    fn handleDirectAck(self: *Manager, id: [16]u8, sequence: u64, payload: []const u8) void {
        const id_hex = std.fmt.bytesToHex(id, .lower);
        self.mutex.lockUncancelable(self.io);
        const state = self.connections.get(&id_hex);
        self.mutex.unlock(self.io);
        const conn = state orelse return;
        if (conn.closed.load(.acquire)) return;

        conn.tx_mutex.lockUncancelable(self.io);
        defer conn.tx_mutex.unlock(self.io);
        if (sequence > conn.tx_next) return;

        if (sequence > conn.tx_base) {
            const cumulative_end = @min(sequence, conn.tx_next);
            var packet_index = conn.tx_base;
            while (packet_index < cumulative_end) : (packet_index += 1) {
                conn.tx_acked[@intCast(packet_index % direct_window)] = true;
            }
        }

        if (payload.len == direct_ack_bitmap_bytes) {
            for (0..direct_window) |bit_index| {
                const packet_index = sequence + @as(u64, @intCast(bit_index));
                if (packet_index < conn.tx_base or packet_index >= conn.tx_next) continue;
                const byte = payload[bit_index / 8];
                const mask = @as(u8, 1) << @intCast(bit_index % 8);
                if (byte & mask != 0) {
                    conn.tx_acked[@intCast(packet_index % direct_window)] = true;
                }
            }
        }
    }

    fn handleDirectData(
        self: *Manager,
        id: [16]u8,
        sequence: u64,
        payload: []const u8,
        from: std.Io.net.IpAddress,
    ) void {
        const mesh_manager = self.mesh_manager orelse return;
        if (payload.len == 0 or payload.len > direct_chunk_size) return;
        const id_hex = std.fmt.bytesToHex(id, .lower);

        self.mutex.lockUncancelable(self.io);
        const maybe_conn = self.connections.get(&id_hex);
        self.mutex.unlock(self.io);
        const conn = maybe_conn orelse return;
        if (conn.closed.load(.acquire)) return;

        const mode_peer = self.forwardModePeer(conn.forward_id);
        if (mode_peer.mode != .direct or mode_peer.peer == null) return;

        var flush_buffer: [direct_window * direct_chunk_size]u8 = undefined;
        var flush_len: usize = 0;
        var ack_bitmap: [direct_ack_bitmap_bytes]u8 = @splat(0);
        var ack_sequence: u64 = 0;

        conn.rx_mutex.lockUncancelable(self.io);
        if (sequence < conn.rx_base) {
            // Duplicate: return the current cumulative/SACK state.
        } else if (sequence < conn.rx_base + direct_window) {
            const slot: usize = @intCast(sequence % direct_window);
            if (!conn.rx_received[slot]) {
                @memcpy(conn.rx_payload[slot][0..payload.len], payload);
                conn.rx_len[slot] = @intCast(payload.len);
                conn.rx_received[slot] = true;
            }
        }

        while (conn.rx_received[@intCast(conn.rx_base % direct_window)]) {
            const slot: usize = @intCast(conn.rx_base % direct_window);
            const len: usize = conn.rx_len[slot];
            @memcpy(flush_buffer[flush_len .. flush_len + len], conn.rx_payload[slot][0..len]);
            flush_len += len;
            conn.rx_received[slot] = false;
            conn.rx_len[slot] = 0;
            conn.rx_base += 1;
        }

        ack_sequence = conn.rx_base;
        for (0..direct_window) |bit_index| {
            const packet_index = conn.rx_base + @as(u64, @intCast(bit_index));
            if (conn.rx_received[@intCast(packet_index % direct_window)]) {
                ack_bitmap[bit_index / 8] |= @as(u8, 1) << @intCast(bit_index % 8);
            }
        }
        conn.rx_mutex.unlock(self.io);

        mesh_manager.send(from, .forward_ack, id, ack_sequence, &ack_bitmap) catch {};

        if (flush_len != 0) {
            conn.write_mutex.lockUncancelable(self.io);
            if (!conn.closed.load(.acquire)) {
                var writer = conn.stream.writer(self.io, &.{});
                writer.interface.writeAll(flush_buffer[0..flush_len]) catch {
                    conn.write_mutex.unlock(self.io);
                    self.failDirectConnection(conn);
                    return;
                };
                writer.interface.flush() catch {
                    conn.write_mutex.unlock(self.io);
                    self.failDirectConnection(conn);
                    return;
                };
            }
            conn.write_mutex.unlock(self.io);
        }
    }

    fn failDirectConnection(self: *Manager, state: *ConnectionState) void {
        state.close();
        self.sendJson(.{
            .type = "forward_connection_close",
            .forwardId = &state.forward_id_text,
            .connectionId = &state.id_text,
        }) catch {};
    }

    fn sendJson(self: *Manager, value: anytype) !void {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(value, .{})});
        try self.transport.writeText(payload.written());
    }
};

fn meshPacket(
    context: *anyopaque,
    packet_type: mesh.PacketType,
    id: [16]u8,
    sequence: u64,
    payload: []const u8,
    from: std.Io.net.IpAddress,
) void {
    const self: *Manager = @ptrCast(@alignCast(context));
    self.handleMeshPacket(packet_type, id, sequence, payload, from);
}

fn parseCandidates(text: []const u8) !CandidateSet {
    var result: CandidateSet = .{};
    var parts = std.mem.splitScalar(u8, text, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (result.count >= result.items.len) return error.TooManyMeshCandidates;
        result.items[result.count] = try mesh.Manager.parseCandidate(trimmed);
        result.count += 1;
    }
    return result;
}

fn forwardProbeMain(state: *ForwardState) void {
    for (0..direct_probe_rounds) |_| {
        if (state.stopped.load(.acquire)) return;

        state.manager.mutex.lockUncancelable(state.manager.io);
        const done = state.mode != .pending or state.direct_peer != null;
        state.manager.mutex.unlock(state.manager.io);
        if (done) return;

        state.manager.probeForward(state);
        state.manager.io.sleep(.fromMilliseconds(direct_probe_interval_ms), .awake) catch return;
    }
}

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
        if (state.stopped.load(.acquire)) {
            stream.close(state.manager.io);
            return;
        }
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

fn waitForwardMode(state: *ConnectionState) !ModePeer {
    for (0..600) |_| {
        if (state.closed.load(.acquire)) return error.ForwardConnectionClosed;
        const mode_peer = state.manager.forwardModePeer(state.forward_id);
        switch (mode_peer.mode) {
            .direct => {
                if (mode_peer.peer == null) return error.DirectForwardPeerMissing;
                return mode_peer;
            },
            .relay => return mode_peer,
            .pending => {},
        }
        try state.manager.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ForwardModeTimeout;
}

fn connectionReader(state: *ConnectionState) !void {
    const mode_peer = try waitForwardMode(state);
    switch (mode_peer.mode) {
        .direct => try connectionReaderDirect(state, mode_peer.peer.?),
        .relay => try connectionReaderRelay(state),
        .pending => unreachable,
    }
}

fn connectionReaderRelay(state: *ConnectionState) !void {
    var reader_buffer: [8192]u8 = undefined;
    var data: [max_relay_chunk_size]u8 = undefined;
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

fn connectionReaderDirect(state: *ConnectionState, peer: std.Io.net.IpAddress) !void {
    var reader_buffer: [8192]u8 = undefined;
    var data: [direct_window * direct_chunk_size]u8 = undefined;
    var reader = state.stream.reader(state.manager.io, &reader_buffer);

    while (!state.closed.load(.acquire)) {
        var slices = [_][]u8{&data};
        const count = reader.interface.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return,
        };
        if (count == 0) continue;
        try sendDirectBlock(state, peer, data[0..count]);
    }
}

fn sendDirectBlock(state: *ConnectionState, peer: std.Io.net.IpAddress, data: []const u8) !void {
    const mesh_manager = state.manager.mesh_manager orelse return error.DirectUnavailable;
    if (data.len == 0) return;

    const chunk_count: usize = (data.len + direct_chunk_size - 1) / direct_chunk_size;
    if (chunk_count > direct_window) return error.DirectForwardBlockTooLarge;

    state.tx_mutex.lockUncancelable(state.manager.io);
    const start_seq = state.tx_next;
    const end_seq = start_seq + chunk_count;
    var seq = start_seq;
    while (seq < end_seq) : (seq += 1) {
        state.tx_acked[@intCast(seq % direct_window)] = false;
    }
    state.tx_base = start_seq;
    state.tx_next = end_seq;
    state.tx_mutex.unlock(state.manager.io);

    var sent_at: [direct_window]i96 = @splat(0);
    var last_base = start_seq;
    var last_progress_ns = std.Io.Clock.awake.now(state.manager.io).nanoseconds;

    while (!state.closed.load(.acquire)) {
        const now_ns = std.Io.Clock.awake.now(state.manager.io).nanoseconds;
        var to_send: [direct_send_budget]u64 = undefined;
        var send_count: usize = 0;

        state.tx_mutex.lockUncancelable(state.manager.io);
        while (state.tx_base < end_seq and state.tx_acked[@intCast(state.tx_base % direct_window)]) {
            state.tx_acked[@intCast(state.tx_base % direct_window)] = false;
            state.tx_base += 1;
        }
        const base = state.tx_base;
        if (base >= end_seq) {
            state.tx_mutex.unlock(state.manager.io);
            return;
        }
        if (base > last_base) {
            last_base = base;
            last_progress_ns = now_ns;
        }
        if (now_ns - last_progress_ns > direct_stall_ns) {
            state.tx_mutex.unlock(state.manager.io);
            return error.DirectForwardStalled;
        }

        seq = base;
        while (seq < end_seq and send_count < to_send.len) : (seq += 1) {
            if (state.tx_acked[@intCast(seq % direct_window)]) continue;
            const local_index: usize = @intCast(seq - start_seq);
            if (sent_at[local_index] == 0 or now_ns - sent_at[local_index] >= direct_retransmit_ns) {
                sent_at[local_index] = now_ns;
                to_send[send_count] = seq;
                send_count += 1;
            }
        }
        state.tx_mutex.unlock(state.manager.io);

        for (to_send[0..send_count]) |packet_seq| {
            const local_index: usize = @intCast(packet_seq - start_seq);
            const offset = local_index * direct_chunk_size;
            const end = @min(data.len, offset + direct_chunk_size);
            mesh_manager.send(peer, .forward_data, state.id, packet_seq, data[offset..end]) catch {};
        }

        if (send_count != 0) {
            const deadline_ns = now_ns + direct_pacing_ns;
            if (builtin.os.tag == .windows) {
                while (std.Io.Clock.awake.now(state.manager.io).nanoseconds < deadline_ns) {
                    std.Thread.yield() catch std.atomic.spinLoopHint();
                }
            } else {
                try state.manager.io.sleep(.fromMilliseconds(1), .awake);
            }
        } else {
            try state.manager.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    return error.ForwardConnectionClosed;
}
