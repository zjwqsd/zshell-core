const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const magic = "ZMD1";
const max_payload: usize = 16 * 1024;
const header_plain_size: usize = 1 + 16 + 8;
const max_plain: usize = header_plain_size + max_payload;
const max_packet: usize = magic.len + Aead.nonce_length + max_plain + Aead.tag_length;
const stun_keepalive_interval_seconds: usize = 10;

pub const PacketType = enum(u8) {
    probe = 1,
    probe_ack = 2,
    file_chunk = 3,
    file_ack = 4,
    forward_probe = 5,
    forward_probe_ack = 6,
    forward_data = 7,
    forward_ack = 8,
};

pub const HandlerSlot = enum { transfer, forward };

pub const Handler = struct {
    context: *anyopaque,
    on_packet: *const fn (*anyopaque, PacketType, [16]u8, u64, []const u8, std.Io.net.IpAddress) void,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Socket,
    key: [Aead.key_length]u8,
    candidate_buffer: [192]u8 = undefined,
    candidate_len: usize = 0,
    handler_mutex: std.Io.Mutex = .init,
    handlers: [2]?Handler = .{ null, null },
    send_mutex: std.Io.Mutex = .init,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    keepalive_thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, token: []const u8) !*Manager {
        const bind_address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
        const socket = try bind_address.bind(io, .{ .mode = .dgram, .protocol = .udp });
        errdefer socket.close(io);

        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);
        var key: [Aead.key_length]u8 = undefined;
        HmacSha256.create(&key, "zshell-mesh-data-v1", token);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .socket = socket,
            .key = key,
        };

        try self.discoverWithDeadline();
        self.keepalive_thread = try std.Thread.spawn(.{}, keepaliveMain, .{self});
        errdefer {
            self.stopped.store(true, .release);
            if (self.keepalive_thread) |thread| thread.join();
            self.keepalive_thread = null;
        }
        self.thread = try std.Thread.spawn(.{}, receiveMain, .{self});
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.stopped.store(true, .release);
        self.socket.close(self.io);
        if (self.thread) |thread| thread.join();
        if (self.keepalive_thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn candidate(self: *const Manager) ?[]const u8 {
        if (self.candidate_len == 0) return null;
        return self.candidate_buffer[0..self.candidate_len];
    }

    pub fn setHandler(self: *Manager, slot: HandlerSlot, handler: ?Handler) void {
        self.handler_mutex.lockUncancelable(self.io);
        self.handlers[@intFromEnum(slot)] = handler;
        self.handler_mutex.unlock(self.io);
    }

    pub fn send(
        self: *Manager,
        destination: std.Io.net.IpAddress,
        packet_type: PacketType,
        transfer_id: [16]u8,
        sequence: u64,
        payload: []const u8,
    ) !void {
        if (payload.len > max_payload) return error.MeshPayloadTooLarge;

        var plain: [max_plain]u8 = undefined;
        plain[0] = @intFromEnum(packet_type);
        @memcpy(plain[1..17], &transfer_id);
        std.mem.writeInt(u64, plain[17..25], sequence, .big);
        @memcpy(plain[25 .. 25 + payload.len], payload);
        const plain_len = header_plain_size + payload.len;

        var nonce: [Aead.nonce_length]u8 = undefined;
        self.io.random(&nonce);
        var ciphertext: [max_plain]u8 = undefined;
        var tag: [Aead.tag_length]u8 = undefined;
        Aead.encrypt(ciphertext[0..plain_len], &tag, plain[0..plain_len], magic, nonce, self.key);

        var packet: [max_packet]u8 = undefined;
        var offset: usize = 0;
        @memcpy(packet[offset .. offset + magic.len], magic);
        offset += magic.len;
        @memcpy(packet[offset .. offset + nonce.len], &nonce);
        offset += nonce.len;
        @memcpy(packet[offset .. offset + plain_len], ciphertext[0..plain_len]);
        offset += plain_len;
        @memcpy(packet[offset .. offset + tag.len], &tag);
        offset += tag.len;

        self.send_mutex.lockUncancelable(self.io);
        defer self.send_mutex.unlock(self.io);
        try self.socket.send(self.io, &destination, packet[0..offset]);
    }

    pub fn parseCandidate(text: []const u8) !std.Io.net.IpAddress {
        return std.Io.net.IpAddress.parseLiteral(text);
    }

    fn discoverWithDeadline(self: *Manager) !void {
        var state = DiscoveryState{ .manager = self };
        const thread = try std.Thread.spawn(.{}, discoveryMain, .{&state});
        var completed = false;
        for (0..20) |_| {
            if (state.done.load(.acquire)) {
                completed = true;
                break;
            }
            try self.io.sleep(.fromMilliseconds(50), .awake);
        }
        if (!completed) {
            self.socket.close(self.io);
            thread.join();
            return error.MeshDiscoveryTimeout;
        }
        thread.join();
        if (!state.ok.load(.acquire)) return error.MeshDiscoveryFailed;
    }

    fn discoverPublicCandidate(self: *Manager) !void {
        const stun_servers = [_]std.Io.net.IpAddress{
            try std.Io.net.IpAddress.parse("162.159.207.0", 3478),
            try std.Io.net.IpAddress.parse("74.125.250.129", 19302),
        };

        var transaction: [12]u8 = undefined;
        self.io.random(&transaction);
        var request: [20]u8 = @splat(0);
        std.mem.writeInt(u16, request[0..2], 0x0001, .big);
        std.mem.writeInt(u16, request[2..4], 0, .big);
        std.mem.writeInt(u32, request[4..8], 0x2112A442, .big);
        @memcpy(request[8..20], &transaction);
        var sent = false;
        for (stun_servers) |server| {
            self.socket.send(self.io, &server, &request) catch continue;
            sent = true;
        }
        if (!sent) return error.StunSendFailed;

        var buffer: [1500]u8 = undefined;
        const message = try self.socket.receive(self.io, &buffer);
        const bytes = message.data;
        if (bytes.len < 20 or !std.mem.eql(u8, bytes[8..20], &transaction)) return error.InvalidStunResponse;

        const msg_len: usize = std.mem.readInt(u16, bytes[2..4], .big);
        const end = @min(bytes.len, 20 + msg_len);
        var offset: usize = 20;
        while (offset + 4 <= end) {
            const attr_type = std.mem.readInt(u16, @ptrCast(bytes[offset..].ptr), .big);
            const attr_len: usize = std.mem.readInt(u16, @ptrCast(bytes[offset + 2 ..].ptr), .big);
            const start = offset + 4;
            if (start + attr_len > end) break;
            if ((attr_type == 0x0020 or attr_type == 0x0001) and attr_len >= 8 and bytes[start + 1] == 0x01) {
                var port = std.mem.readInt(u16, @ptrCast(bytes[start + 2 ..].ptr), .big);
                var ip_bytes: [4]u8 = undefined;
                @memcpy(&ip_bytes, bytes[start + 4 .. start + 8]);
                if (attr_type == 0x0020) {
                    port ^= @as(u16, 0x2112);
                    const cookie = [_]u8{ 0x21, 0x12, 0xA4, 0x42 };
                    for (&ip_bytes, cookie) |*byte, mask| byte.* ^= mask;
                }
                const public_address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = ip_bytes, .port = port } };
                const rendered = if (self.localRouteCandidate(stun_servers[0])) |local_address|
                    try std.fmt.bufPrint(&self.candidate_buffer, "{f};{f}", .{ local_address, public_address })
                else
                    try std.fmt.bufPrint(&self.candidate_buffer, "{f}", .{public_address});
                self.candidate_len = rendered.len;
                std.log.info("mesh candidates: {s}", .{rendered});
                return;
            }
            offset = start + ((attr_len + 3) & ~@as(usize, 3));
        }
        return error.StunMappedAddressMissing;
    }

    fn localRouteCandidate(self: *Manager, remote: std.Io.net.IpAddress) ?std.Io.net.IpAddress {
        const stream = remote.connect(self.io, .{
            .mode = .dgram,
            .protocol = .udp,
        }) catch return null;
        defer stream.close(self.io);

        var local = stream.socket.address;
        const mesh_port = self.socket.address.getPort();
        switch (local) {
            .ip4 => |*ip4| {
                if (std.mem.eql(u8, &ip4.bytes, &[_]u8{ 0, 0, 0, 0 }) or
                    ip4.bytes[0] == 127)
                {
                    return null;
                }
                ip4.port = mesh_port;
            },
            .ip6 => |*ip6| {
                ip6.port = mesh_port;
            },
        }
        return local;
    }

    fn sendStunKeepalive(self: *Manager) void {
        const stun_servers = [_]std.Io.net.IpAddress{
            std.Io.net.IpAddress.parse("162.159.207.0", 3478) catch return,
            std.Io.net.IpAddress.parse("74.125.250.129", 19302) catch return,
        };

        var transaction: [12]u8 = undefined;
        self.io.random(&transaction);
        var request: [20]u8 = @splat(0);
        std.mem.writeInt(u16, request[0..2], 0x0001, .big);
        std.mem.writeInt(u16, request[2..4], 0, .big);
        std.mem.writeInt(u32, request[4..8], 0x2112A442, .big);
        @memcpy(request[8..20], &transaction);

        self.send_mutex.lockUncancelable(self.io);
        defer self.send_mutex.unlock(self.io);
        for (stun_servers) |server| {
            self.socket.send(self.io, &server, &request) catch {};
        }
    }

    fn keepaliveMain(self: *Manager) void {
        while (!self.stopped.load(.acquire)) {
            for (0..stun_keepalive_interval_seconds) |_| {
                if (self.stopped.load(.acquire)) return;
                self.io.sleep(.fromSeconds(1), .awake) catch return;
            }
            if (self.stopped.load(.acquire)) return;
            self.sendStunKeepalive();
        }
    }

    fn receiveMain(self: *Manager) void {
        self.receiveLoop() catch |err| {
            if (!self.stopped.load(.acquire)) {
                std.log.warn("mesh receive stopped: {s}", .{@errorName(err)});
            }
        };
    }

    fn receiveLoop(self: *Manager) !void {
        var packet_buffer: [max_packet]u8 = undefined;
        var plain: [max_plain]u8 = undefined;

        while (!self.stopped.load(.acquire)) {
            const message = try self.socket.receive(self.io, &packet_buffer);
            const packet = message.data;
            if (packet.len < magic.len + Aead.nonce_length + Aead.tag_length + header_plain_size) continue;
            if (!std.mem.eql(u8, packet[0..magic.len], magic)) continue;

            var nonce: [Aead.nonce_length]u8 = undefined;
            @memcpy(&nonce, packet[magic.len .. magic.len + Aead.nonce_length]);
            const cipher_start = magic.len + Aead.nonce_length;
            const cipher_end = packet.len - Aead.tag_length;
            const cipher = packet[cipher_start..cipher_end];
            if (cipher.len > plain.len) continue;
            var tag: [Aead.tag_length]u8 = undefined;
            @memcpy(&tag, packet[cipher_end..]);
            Aead.decrypt(plain[0..cipher.len], cipher, tag, magic, nonce, self.key) catch continue;
            if (cipher.len < header_plain_size) continue;

            const packet_type: PacketType = switch (plain[0]) {
                1 => .probe,
                2 => .probe_ack,
                3 => .file_chunk,
                4 => .file_ack,
                5 => .forward_probe,
                6 => .forward_probe_ack,
                7 => .forward_data,
                8 => .forward_ack,
                else => continue,
            };
            var transfer_id: [16]u8 = undefined;
            @memcpy(&transfer_id, plain[1..17]);
            const sequence = std.mem.readInt(u64, plain[17..25], .big);
            const payload = plain[25..cipher.len];

            self.handler_mutex.lockUncancelable(self.io);
            const handlers = self.handlers;
            self.handler_mutex.unlock(self.io);
            for (handlers) |maybe_handler| {
                if (maybe_handler) |handler| {
                    handler.on_packet(handler.context, packet_type, transfer_id, sequence, payload, message.from);
                }
            }
        }
    }
};

const DiscoveryState = struct {
    manager: *Manager,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn discoveryMain(state: *DiscoveryState) void {
    state.manager.discoverPublicCandidate() catch {
        state.done.store(true, .release);
        return;
    };
    state.ok.store(true, .release);
    state.done.store(true, .release);
}
