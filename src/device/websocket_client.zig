const std = @import("std");

const max_message_size: usize = 8 * 1024 * 1024;
const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    connection: *std.http.Client.Connection,

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        token: []const u8,
    ) !Connection {
        const uri = try std.Uri.parse(url);
        if (!std.mem.eql(u8, uri.scheme, "ws") and !std.mem.eql(u8, uri.scheme, "wss")) {
            return error.UnsupportedWebSocketScheme;
        }

        const client = try allocator.create(std.http.Client);
        errdefer allocator.destroy(client);
        client.* = .{ .allocator = allocator, .io = io };
        errdefer client.deinit();

        var key_source: [16]u8 = undefined;
        io.random(&key_source);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_source);

        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer allocator.free(authorization);
        const extra_headers = [_]std.http.Header{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "sec-websocket-version", .value = "13" },
            .{ .name = "sec-websocket-key", .value = &key },
        };

        var request = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = authorization },
                .connection = .{ .override = "Upgrade" },
            },
            .extra_headers = &extra_headers,
        });
        var request_detached = false;
        defer if (!request_detached) request.deinit();

        try request.sendBodiless();
        const response = try request.receiveHead(&.{});
        if (response.head.status != .switching_protocols) {
            return error.WebSocketUpgradeRejected;
        }
        try validateUpgradeResponse(response.head, &key);

        const connection = request.connection orelse return error.WebSocketConnectionMissing;
        request.connection = null;
        request.deinit();
        request_detached = true;

        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .connection = connection,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.* = undefined;
    }

    pub fn readText(self: *Connection) ![]u8 {
        while (true) {
            const message = try self.readFrame();
            switch (message.opcode) {
                .text => return message.payload,
                .ping => {
                    defer self.allocator.free(message.payload);
                    try self.writeFrame(.pong, message.payload);
                },
                .pong => self.allocator.free(message.payload),
                .connection_close => {
                    defer self.allocator.free(message.payload);
                    self.writeFrame(.connection_close, message.payload) catch {};
                    return error.WebSocketClosed;
                },
                else => {
                    self.allocator.free(message.payload);
                    return error.UnsupportedWebSocketOpcode;
                },
            }
        }
    }

    pub fn writeText(self: *Connection, payload: []const u8) !void {
        try self.writeFrame(.text, payload);
    }

    const Opcode = enum(u4) {
        continuation = 0,
        text = 1,
        binary = 2,
        connection_close = 8,
        ping = 9,
        pong = 10,
        _,
    };

    const Message = struct {
        opcode: Opcode,
        payload: []u8,
    };

    fn readFrame(self: *Connection) !Message {
        const reader = self.connection.reader();
        var header: [2]u8 = undefined;
        try reader.readSliceAll(&header);

        const fin = (header[0] & 0x80) != 0;
        if (!fin or (header[0] & 0x70) != 0) return error.UnsupportedWebSocketFrame;
        const opcode: Opcode = @enumFromInt(header[0] & 0x0f);

        // Servers must not mask frames sent to clients.
        if ((header[1] & 0x80) != 0) return error.MaskedServerFrame;
        var length: u64 = header[1] & 0x7f;
        if (length == 126) {
            var ext: [2]u8 = undefined;
            try reader.readSliceAll(&ext);
            length = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (length == 127) {
            var ext: [8]u8 = undefined;
            try reader.readSliceAll(&ext);
            if ((ext[0] & 0x80) != 0) return error.InvalidWebSocketLength;
            length = 0;
            for (ext) |byte| length = (length << 8) | byte;
        }

        const is_control = @intFromEnum(opcode) >= 8;
        if (is_control and length > 125) return error.InvalidControlFrame;
        if (length > max_message_size) return error.WebSocketMessageTooLarge;
        const payload_len: usize = @intCast(length);
        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);
        if (payload_len != 0) try reader.readSliceAll(payload);

        return .{ .opcode = opcode, .payload = payload };
    }

    fn writeFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        if (payload.len > max_message_size) return error.WebSocketMessageTooLarge;
        if (@intFromEnum(opcode) >= 8 and payload.len > 125) return error.InvalidControlFrame;

        const writer = self.connection.writer();
        try writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
        if (payload.len <= 125) {
            try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= 0xffff) {
            try writer.writeByte(0x80 | 126);
            try writer.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try writer.writeByte(0x80 | 127);
            try writer.writeInt(u64, @intCast(payload.len), .big);
        }

        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        try writer.writeAll(&mask);

        var offset: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (offset < payload.len) {
            const count = @min(buffer.len, payload.len - offset);
            for (payload[offset .. offset + count], 0..) |byte, i| {
                buffer[i] = byte ^ mask[(offset + i) % mask.len];
            }
            try writer.writeAll(buffer[0..count]);
            offset += count;
        }
        try self.connection.flush();
    }
};

fn validateUpgradeResponse(head: std.http.Client.Response.Head, key: []const u8) !void {
    var accept: ?[]const u8 = null;
    var upgrade_ok = false;
    var connection_ok = false;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            accept = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            upgrade_ok = std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "websocket");
        } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            connection_ok = containsToken(header.value, "upgrade");
        }
    }
    if (!upgrade_ok or !connection_ok) return error.InvalidWebSocketUpgrade;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(websocket_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var expected: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&expected, &digest);
    const actual = accept orelse return error.MissingWebSocketAccept;
    if (!std.mem.eql(u8, std.mem.trim(u8, actual, " \t"), &expected)) {
        return error.InvalidWebSocketAccept;
    }
}

fn containsToken(value: []const u8, expected: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), expected)) return true;
    }
    return false;
}
