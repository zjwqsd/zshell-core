const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport.zig");
const control = @import("../control/state.zig");
const mesh = @import("mesh.zig");

pub const binary_magic = transport.binary_magic;
pub const binary_header_size = transport.binary_header_size;

const Sha256 = std.crypto.hash.sha2.Sha256;

const direct_public_chunk_size: usize = 1000;
const direct_lan_chunk_size: usize = 8 * 1024;
const direct_window: usize = 256;
const direct_ack_every_packets: usize = 16;
const direct_ack_bitmap_bytes: usize = direct_window / 8;
const direct_probe_rounds: usize = 8;
const direct_probe_wait_rounds: usize = 100;
const direct_probe_interval_ms: u64 = 50;
const direct_retransmit_ns: i96 = 150 * std.time.ns_per_ms;
const direct_stall_ns: i96 = 4 * std.time.ns_per_s;
const direct_progress_bytes: u64 = 1024 * 1024;
const direct_public_send_budget: usize = 8;
const direct_public_pacing_ns: i96 = 250 * std.time.ns_per_us;
const max_peer_candidates: usize = 4;

const CandidateSet = struct {
    items: [max_peer_candidates]?std.Io.net.IpAddress = @splat(null),
    count: usize = 0,
};

const SourceState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *Manager,
    transport: *transport.DeviceTransport,
    id: [16]u8,
    id_text: [32]u8,
    path: []u8,
    size: u64,
    direct: bool = false,
    peer_candidates: [max_peer_candidates]?std.Io.net.IpAddress = @splat(null),
    direct_peer: ?std.Io.net.IpAddress = null,
    chunk_size: usize = direct_public_chunk_size,
    direct_started_ns: i96 = 0,
    ack_base: u64 = 0,
    ack_next: u64 = 0,
    acked: [direct_window]bool = @splat(false),
    sent_ns: [direct_window]i96 = @splat(0),
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
    manager: *Manager,
    id: [16]u8,
    id_text: [32]u8,
    final_path: []u8,
    part_path: []u8,
    overwrite: bool,
    direct: bool = false,
    direct_mode: bool = false,
    peer_candidates: [max_peer_candidates]?std.Io.net.IpAddress = @splat(null),
    direct_peer: ?std.Io.net.IpAddress = null,
    recv_chunk_size: usize = 0,
    recv_base: u64 = 0,
    recv_received: [direct_window]bool = @splat(false),
    expected_size: u64 = 0,
    ack_pending_packets: usize = 0,
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
    mesh_manager: ?*mesh.Manager,
    mutex: std.Io.Mutex = .init,
    source: ?*SourceState = null,
    target: ?*TargetState = null,

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
        manager.setHandler(.{
            .context = @ptrCast(self),
            .on_packet = meshPacket,
        });
    }

    pub fn detachMeshHandler(self: *Manager) void {
        const manager = self.mesh_manager orelse return;
        manager.setHandler(null);
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
                direct: bool = false,
                peerCandidate: []const u8 = "",
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.prepareSource(
                parsed.value.transferId,
                parsed.value.path,
                parsed.value.direct,
                parsed.value.peerCandidate,
            ) catch |err| {
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
                direct: bool = false,
                peerCandidate: []const u8 = "",
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            self.prepareTarget(
                parsed.value.transferId,
                parsed.value.path,
                parsed.value.overwrite,
                parsed.value.direct,
                parsed.value.peerCandidate,
            ) catch |err| {
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

        if (std.mem.eql(u8, header.value.type, "transfer_direct_config")) {
            const Message = struct {
                type: []const u8,
                transferId: []const u8,
                size: u64,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            try self.configureDirectTarget(parsed.value.transferId, parsed.value.size);
            return true;
        }

        if (std.mem.eql(u8, header.value.type, "transfer_direct_ack")) {
            const Message = struct {
                type: []const u8,
                transferId: []const u8,
                nextChunk: u64,
            };
            const parsed = try std.json.parseFromSlice(Message, self.allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            try self.applyDirectAck(parsed.value.transferId, parsed.value.nextChunk);
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
        if (state.direct_mode and sequence == 0) {
            state.direct_mode = false;
            state.bytes_written = 0;
            state.next_sequence = 0;
            state.recv_chunk_size = 0;
            state.recv_base = 0;
            state.recv_received = @splat(false);
            state.expected_size = 0;
            state.ack_pending_packets = 0;
            state.hasher = Sha256.init(.{});
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

    fn prepareSource(
        self: *Manager,
        id_text: []const u8,
        path: []const u8,
        direct: bool,
        peer_candidate_text: []const u8,
    ) !void {
        if (path.len == 0) return error.EmptyTransferPath;
        const id = try parseTransferId(id_text);
        try self.reapFinishedSource();

        const info = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = true });
        if (info.kind != .file) return error.TransferSourceNotFile;
        const peer_candidates = parseCandidateSet(peer_candidate_text);

        const state = try self.allocator.create(SourceState);
        errdefer self.allocator.destroy(state);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        state.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .manager = self,
            .transport = self.transport,
            .id = id,
            .id_text = std.fmt.bytesToHex(id, .lower),
            .path = owned_path,
            .size = info.size,
            .direct = direct and self.mesh_manager != null and peer_candidates.count != 0,
            .peer_candidates = peer_candidates.items,
        };

        self.mutex.lockUncancelable(self.io);
        if (self.source != null) {
            self.mutex.unlock(self.io);
            state.deinit();
            return error.TransferSourceBusy;
        }
        self.source = state;
        self.mutex.unlock(self.io);

        if (state.direct) self.probeBurst(state.id, state.peer_candidates);
        try self.sendJson(.{
            .type = "transfer_source_ready",
            .transferId = &state.id_text,
            .size = state.size,
        });
    }

    fn prepareTarget(
        self: *Manager,
        id_text: []const u8,
        path: []const u8,
        overwrite: bool,
        direct: bool,
        peer_candidate_text: []const u8,
    ) !void {
        try control.requireAgent(self.io);
        if (path.len == 0) return error.EmptyTransferPath;
        const id = try parseTransferId(id_text);
        const peer_candidates = parseCandidateSet(peer_candidate_text);

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
            .manager = self,
            .id = id,
            .id_text = std.fmt.bytesToHex(id, .lower),
            .final_path = final_path,
            .part_path = part_path,
            .overwrite = overwrite,
            .direct = direct and self.mesh_manager != null and peer_candidates.count != 0,
            .peer_candidates = peer_candidates.items,
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

        if (state.direct) self.probeBurst(state.id, state.peer_candidates);
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
        var digest: [Sha256.digest_length]u8 = undefined;
        if (state.direct_mode) {
            const info = state.file.stat(self.io) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            if (info.size != expected_size) {
                self.mutex.unlock(self.io);
                return error.TransferSizeMismatch;
            }
            hashFile(state.file, self.io, expected_size, &digest) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            state.bytes_written = expected_size;
        } else {
            if (state.bytes_written != expected_size) {
                self.mutex.unlock(self.io);
                return error.TransferSizeMismatch;
            }
            state.hasher.final(&digest);
        }
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

    fn configureDirectTarget(self: *Manager, id_text: []const u8, size: u64) !void {
        const id = try parseTransferId(id_text);
        self.mutex.lockUncancelable(self.io);
        const state = self.target orelse {
            self.mutex.unlock(self.io);
            return error.TransferTargetNotPrepared;
        };
        if (!std.mem.eql(u8, &state.id, &id)) {
            self.mutex.unlock(self.io);
            return error.TransferIdMismatch;
        }
        if (!state.direct) {
            self.mutex.unlock(self.io);
            return error.DirectUnavailable;
        }
        state.expected_size = size;
        const candidates = state.peer_candidates;
        self.mutex.unlock(self.io);

        // The initial target probe burst can run before the source has opened
        // its NAT filter. Once both peers are ready, keep punching from the
        // target side while the source performs the same negotiation.
        for (0..direct_probe_wait_rounds) |_| {
            self.mutex.lockUncancelable(self.io);
            const current = self.target;
            const active = if (current) |candidate|
                candidate.direct and std.mem.eql(u8, &candidate.id, &id)
            else
                false;
            const peer = if (current) |candidate| candidate.direct_peer else null;
            self.mutex.unlock(self.io);

            if (!active or peer != null) break;
            self.probeOnce(id, candidates);
            try self.io.sleep(.fromMilliseconds(direct_probe_interval_ms), .awake);
        }
    }

    fn applyDirectAck(self: *Manager, id_text: []const u8, next_chunk: u64) !void {
        const id = try parseTransferId(id_text);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.source orelse return;
        if (!state.direct or !std.mem.eql(u8, &state.id, &id)) return;
        if (next_chunk <= state.ack_base or next_chunk > state.ack_next or
            next_chunk - state.ack_base > direct_window)
        {
            return;
        }
        var chunk_index = state.ack_base;
        while (chunk_index < next_chunk) : (chunk_index += 1) {
            state.acked[@intCast(chunk_index % direct_window)] = true;
        }
    }

    fn probeOnce(self: *Manager, id: [16]u8, candidates: [max_peer_candidates]?std.Io.net.IpAddress) void {
        const mesh_manager = self.mesh_manager orelse return;
        for (candidates) |candidate| {
            const destination = candidate orelse continue;
            mesh_manager.send(destination, .probe, id, 0, &.{}) catch {};
        }
    }

    fn probeBurst(self: *Manager, id: [16]u8, candidates: [max_peer_candidates]?std.Io.net.IpAddress) void {
        for (0..direct_probe_rounds) |_| self.probeOnce(id, candidates);
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
            .probe => {
                var matched = false;
                self.mutex.lockUncancelable(self.io);
                if (self.source) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id)) {
                        state.direct_peer = preferredPeer(state.direct_peer, from);
                        matched = true;
                    }
                }
                if (self.target) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id)) {
                        state.direct_peer = preferredPeer(state.direct_peer, from);
                        matched = true;
                    }
                }
                self.mutex.unlock(self.io);
                if (matched) mesh_manager.send(from, .probe_ack, id, 0, &.{}) catch {};
            },
            .probe_ack => {
                self.mutex.lockUncancelable(self.io);
                if (self.source) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id)) state.direct_peer = preferredPeer(state.direct_peer, from);
                }
                if (self.target) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id)) state.direct_peer = preferredPeer(state.direct_peer, from);
                }
                self.mutex.unlock(self.io);
            },
            .file_ack => {
                self.mutex.lockUncancelable(self.io);
                if (self.source) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id) and sequence <= state.ack_next) {
                        if (sequence > state.ack_base) {
                            const cumulative_end = @min(sequence, state.ack_next);
                            var chunk_index = state.ack_base;
                            while (chunk_index < cumulative_end) : (chunk_index += 1) {
                                state.acked[@intCast(chunk_index % direct_window)] = true;
                            }
                        }

                        if (payload.len == direct_ack_bitmap_bytes) {
                            for (0..direct_window) |bit_index| {
                                const chunk_index = sequence + @as(u64, @intCast(bit_index));
                                if (chunk_index < state.ack_base or chunk_index >= state.ack_next) continue;
                                const byte = payload[bit_index / 8];
                                const mask = @as(u8, 1) << @intCast(bit_index % 8);
                                if (byte & mask != 0) {
                                    state.acked[@intCast(chunk_index % direct_window)] = true;
                                }
                            }
                        }
                    }
                }
                self.mutex.unlock(self.io);
            },
            .file_chunk => {
                if (payload.len == 0 or payload.len > direct_lan_chunk_size) return;
                var ack_value: ?u64 = null;
                var ack_bitmap: [direct_ack_bitmap_bytes]u8 = @splat(0);

                self.mutex.lockUncancelable(self.io);
                if (self.target) |state| {
                    if (state.direct and std.mem.eql(u8, &state.id, &id)) {
                        if (state.recv_chunk_size == 0) {
                            if (sequence == 0) {
                                state.recv_chunk_size = if (payload.len > direct_public_chunk_size)
                                    direct_lan_chunk_size
                                else if (payload.len == direct_public_chunk_size)
                                    direct_public_chunk_size
                                else
                                    payload.len;
                            } else if (payload.len == direct_lan_chunk_size) {
                                state.recv_chunk_size = direct_lan_chunk_size;
                            } else if (payload.len == direct_public_chunk_size) {
                                state.recv_chunk_size = direct_public_chunk_size;
                            } else {
                                self.mutex.unlock(self.io);
                                return;
                            }
                        }

                        const chunk_size = state.recv_chunk_size;
                        if (chunk_size == 0 or sequence % chunk_size != 0) {
                            self.mutex.unlock(self.io);
                            return;
                        }

                        const chunk_index = sequence / chunk_size;
                        var should_ack = false;
                        if (chunk_index < state.recv_base) {
                            should_ack = true;
                        } else if (chunk_index < state.recv_base + direct_window) {
                            const index: usize = @intCast(chunk_index % direct_window);
                            if (!state.recv_received[index]) {
                                state.file.writePositionalAll(self.io, payload, sequence) catch {
                                    self.mutex.unlock(self.io);
                                    return;
                                };
                                state.recv_received[index] = true;
                                state.bytes_written = @max(state.bytes_written, sequence + payload.len);
                                state.ack_pending_packets += 1;
                            } else {
                                should_ack = true;
                            }

                            while (state.recv_received[@intCast(state.recv_base % direct_window)]) {
                                state.recv_received[@intCast(state.recv_base % direct_window)] = false;
                                state.recv_base += 1;
                            }

                            const total_chunks = if (state.expected_size == 0 or chunk_size == 0)
                                @as(u64, 0)
                            else
                                (state.expected_size + chunk_size - 1) / chunk_size;
                            should_ack = should_ack or
                                state.ack_pending_packets >= direct_ack_every_packets or
                                (total_chunks != 0 and state.recv_base >= total_chunks);
                        } else {
                            should_ack = true;
                        }

                        if (should_ack) {
                            state.ack_pending_packets = 0;
                            ack_value = state.recv_base;
                            for (0..direct_window) |bit_index| {
                                const buffered_chunk = state.recv_base + @as(u64, @intCast(bit_index));
                                if (state.recv_received[@intCast(buffered_chunk % direct_window)]) {
                                    ack_bitmap[bit_index / 8] |= @as(u8, 1) << @intCast(bit_index % 8);
                                }
                            }
                        }

                        state.direct_mode = true;
                        state.direct_peer = from;
                    }
                }
                self.mutex.unlock(self.io);

                if (ack_value) |next_chunk| {
                    mesh_manager.send(from, .file_ack, id, next_chunk, &ack_bitmap) catch {};
                }
            },
        }
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

fn sourceWorkerMain(state: *SourceState) void {
    sourceWorker(state) catch |err| {
        sendSourceFailure(state, err) catch {};
    };
    state.done.store(true, .release);
}

fn sourceWorker(state: *SourceState) !void {
    if (state.direct and state.manager.mesh_manager != null) {
        directSourceWorker(state) catch |err| switch (err) {
            error.DirectUnavailable, error.DirectStalled => {
                std.log.info("direct transfer unavailable; using gateway relay", .{});
                return relaySourceWorker(state);
            },
            error.DirectCancelled => return sendSourceCancelled(state),
            else => return err,
        };
        return;
    }
    return relaySourceWorker(state);
}

fn relaySourceWorker(state: *SourceState) !void {
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

fn directSourceWorker(state: *SourceState) !void {
    var file = try std.Io.Dir.cwd().openFile(state.io, state.path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(state.io);

    if (state.size == 0) {
        var digest: [Sha256.digest_length]u8 = undefined;
        var hasher = Sha256.init(.{});
        hasher.final(&digest);
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        try sendSourceJson(state, .{
            .type = "transfer_progress",
            .transferId = &state.id_text,
            .size = @as(u64, 0),
        });
        try sendSourceJson(state, .{
            .type = "transfer_source_finish",
            .transferId = &state.id_text,
            .size = @as(u64, 0),
            .sha256 = &digest_hex,
        });
        return;
    }

    const initial_peer = try waitForDirectPeer(state);
    const lan_path = isPrivateIPv4(initial_peer);
    const chunk_size: usize = if (lan_path) direct_lan_chunk_size else direct_public_chunk_size;
    const send_budget: usize = if (lan_path) 1 else direct_public_send_budget;
    state.manager.mutex.lockUncancelable(state.io);
    state.chunk_size = chunk_size;
    state.direct_started_ns = std.Io.Clock.awake.now(state.io).nanoseconds;
    state.manager.mutex.unlock(state.io);

    const total_chunks = (state.size + chunk_size - 1) / chunk_size;
    var last_progress_ns = std.Io.Clock.awake.now(state.io).nanoseconds;
    var last_reported: u64 = 0;
    var buffer: [direct_lan_chunk_size]u8 = undefined;

    while (true) {
        if (state.cancelled.load(.acquire)) {
            try sendSourceCancelled(state);
            return;
        }

        const now_ns = std.Io.Clock.awake.now(state.io).nanoseconds;
        var to_send: [direct_window]u64 = undefined;
        var send_count: usize = 0;
        var current_peer: ?std.Io.net.IpAddress = null;
        var transferred: u64 = 0;
        var complete = false;
        var progressed = false;

        state.manager.mutex.lockUncancelable(state.io);
        while (state.ack_base < state.ack_next and state.acked[@intCast(state.ack_base % direct_window)]) {
            state.acked[@intCast(state.ack_base % direct_window)] = false;
            state.ack_base += 1;
            progressed = true;
        }
        if (progressed) last_progress_ns = now_ns;

        while (state.ack_next < total_chunks and state.ack_next - state.ack_base < direct_window) {
            const index: usize = @intCast(state.ack_next % direct_window);
            state.acked[index] = false;
            state.sent_ns[index] = 0;
            state.ack_next += 1;
        }

        var sequence = state.ack_base;
        while (sequence < state.ack_next) : (sequence += 1) {
            const index: usize = @intCast(sequence % direct_window);
            if (!state.acked[index] and
                (state.sent_ns[index] == 0 or now_ns - state.sent_ns[index] >= direct_retransmit_ns))
            {
                if (send_count < send_budget) {
                    to_send[send_count] = sequence;
                    send_count += 1;
                    state.sent_ns[index] = now_ns;
                }
                if (send_count >= send_budget) break;
            }
        }

        current_peer = state.direct_peer;
        complete = state.ack_base == total_chunks;
        transferred = @min(state.size, state.ack_base * chunk_size);
        state.manager.mutex.unlock(state.io);

        if (transferred == state.size or transferred -| last_reported >= direct_progress_bytes) {
            try sendSourceJson(state, .{
                .type = "transfer_progress",
                .transferId = &state.id_text,
                .size = transferred,
            });
            last_reported = transferred;
        }

        if (complete) break;
        if (now_ns - last_progress_ns >= direct_stall_ns) return error.DirectStalled;

        const destination = current_peer orelse return error.DirectUnavailable;
        for (to_send[0..send_count]) |seq| {
            const offset = seq * chunk_size;
            const remaining = state.size - offset;
            const wanted: usize = @intCast(@min(remaining, chunk_size));
            const count = try file.readPositionalAll(state.io, buffer[0..wanted], offset);
            if (count != wanted) return error.TransferSourceChanged;
            state.manager.mesh_manager.?.send(destination, .file_chunk, state.id, offset, buffer[0..count]) catch {};
        }

        if (!lan_path and send_count > 0 and builtin.os.tag == .windows) {
            const deadline_ns = now_ns + direct_public_pacing_ns;
            while (std.Io.Clock.awake.now(state.io).nanoseconds < deadline_ns) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        } else {
            try state.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    const final_info = try file.stat(state.io);
    if (final_info.size != state.size) return error.TransferSourceChanged;

    var digest: [Sha256.digest_length]u8 = undefined;
    try hashFile(file, state.io, state.size, &digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try sendSourceJson(state, .{
        .type = "transfer_progress",
        .transferId = &state.id_text,
        .size = state.size,
    });
    try sendSourceJson(state, .{
        .type = "transfer_source_finish",
        .transferId = &state.id_text,
        .size = state.size,
        .sha256 = &digest_hex,
    });
}

fn waitForDirectPeer(state: *SourceState) !std.Io.net.IpAddress {
    for (0..direct_probe_wait_rounds) |_| {
        if (state.cancelled.load(.acquire)) return error.DirectCancelled;
        state.manager.mutex.lockUncancelable(state.io);
        const peer = state.direct_peer;
        const candidates = state.peer_candidates;
        state.manager.mutex.unlock(state.io);
        if (peer) |address| return address;
        state.manager.probeOnce(state.id, candidates);
        try state.io.sleep(.fromMilliseconds(direct_probe_interval_ms), .awake);
    }
    return error.DirectUnavailable;
}

fn hashFile(file: std.Io.File, io: std.Io, size: u64, digest: *[Sha256.digest_length]u8) !void {
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const remaining = size - offset;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count != wanted) return error.TransferSourceChanged;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    hasher.final(digest);
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

fn parseCandidateSet(text: []const u8) CandidateSet {
    var result: CandidateSet = .{};
    var iterator = std.mem.splitScalar(u8, text, ';');
    while (iterator.next()) |item| {
        if (result.count >= max_peer_candidates) break;
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        const address = mesh.Manager.parseCandidate(trimmed) catch continue;
        result.items[result.count] = address;
        result.count += 1;
    }
    return result;
}

fn preferredPeer(current: ?std.Io.net.IpAddress, incoming: std.Io.net.IpAddress) std.Io.net.IpAddress {
    const existing = current orelse return incoming;
    if (isPrivateIPv4(incoming) and !isPrivateIPv4(existing)) return incoming;
    return existing;
}

fn isPrivateIPv4(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| blk: {
            const b = ip4.bytes;
            break :blk b[0] == 10 or
                (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
                (b[0] == 192 and b[1] == 168);
        },
        .ip6 => false,
    };
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

test "candidate set parses multiple endpoints and prefers private IPv4" {
    const candidates = parseCandidateSet("192.168.50.10:12345;203.0.113.7:54321");
    try std.testing.expectEqual(@as(usize, 2), candidates.count);
    const private = candidates.items[0].?;
    const public = candidates.items[1].?;
    try std.testing.expect(isPrivateIPv4(private));
    try std.testing.expect(!isPrivateIPv4(public));
    try std.testing.expect(isPrivateIPv4(preferredPeer(public, private)));
}
