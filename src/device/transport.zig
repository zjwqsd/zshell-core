const std = @import("std");
const websocket = @import("websocket_client.zig");
const http = @import("http_client.zig");

pub const websocket_chunk_size: usize = 256 * 1024;
pub const http_chunk_size: usize = 1024 * 1024;
pub const binary_magic = "ZTF1";
pub const binary_header_size: usize = binary_magic.len + 16 + 8;

pub const Kind = enum {
    websocket,
    http,
};

pub const MessageKind = enum {
    text,
    binary,
};

pub const Message = struct {
    kind: MessageKind,
    payload: []u8,
};

pub const DeviceTransport = union(Kind) {
    websocket: websocket.Connection,
    http: http.Connection,

    pub fn kindForURL(url: []const u8) !Kind {
        if (std.mem.startsWith(u8, url, "ws://") or std.mem.startsWith(u8, url, "wss://")) return .websocket;
        if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return .http;
        return error.UnsupportedGatewayScheme;
    }

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        token: []const u8,
    ) !DeviceTransport {
        return switch (try kindForURL(url)) {
            .websocket => .{ .websocket = try websocket.Connection.connect(allocator, io, url, token) },
            .http => .{ .http = try http.Connection.connect(allocator, io, url, token) },
        };
    }

    pub fn deinit(self: *DeviceTransport) void {
        switch (self.*) {
            .websocket => |*connection| connection.deinit(),
            .http => |*connection| connection.deinit(),
        }
        self.* = undefined;
    }

    pub fn interrupt(self: *DeviceTransport) void {
        switch (self.*) {
            .websocket => |*connection| connection.interrupt(),
            .http => |*connection| connection.interrupt(),
        }
    }

    pub fn name(self: *const DeviceTransport) []const u8 {
        return switch (self.*) {
            .websocket => "websocket",
            .http => "http",
        };
    }

    pub fn transferChunkSize(self: *const DeviceTransport) usize {
        return switch (self.*) {
            .websocket => websocket_chunk_size,
            .http => http_chunk_size,
        };
    }

    pub fn writeText(self: *DeviceTransport, payload: []const u8) !void {
        return switch (self.*) {
            .websocket => |*connection| connection.writeText(payload),
            .http => |*connection| connection.writeText(payload),
        };
    }

    pub fn readMessage(self: *DeviceTransport, allocator: std.mem.Allocator) !Message {
        switch (self.*) {
            .websocket => |*connection| {
                const message = try connection.readMessage();
                return .{
                    .kind = switch (message.kind) {
                        .text => .text,
                        .binary => .binary,
                    },
                    .payload = message.payload,
                };
            },
            .http => |*connection| {
                const control = try connection.readControl();
                const Header = struct { type: []const u8 };
                const header = std.json.parseFromSlice(Header, allocator, control, .{ .ignore_unknown_fields = true }) catch {
                    return .{ .kind = .text, .payload = control };
                };
                defer header.deinit();
                if (!std.mem.eql(u8, header.value.type, "transport_chunk")) {
                    return .{ .kind = .text, .payload = control };
                }

                const Notice = struct {
                    type: []const u8,
                    transferId: []const u8,
                    sequence: u64,
                };
                const notice = try std.json.parseFromSlice(Notice, allocator, control, .{ .ignore_unknown_fields = false });
                defer notice.deinit();
                const id = try parseTransferId(notice.value.transferId);
                const chunk = try connection.downloadTransferChunk(notice.value.transferId, notice.value.sequence);
                defer allocator.free(chunk);
                allocator.free(control);

                const frame = try allocator.alloc(u8, binary_header_size + chunk.len);
                @memcpy(frame[0..binary_magic.len], binary_magic);
                @memcpy(frame[binary_magic.len .. binary_magic.len + id.len], &id);
                const sequence_offset = binary_magic.len + id.len;
                std.mem.writeInt(u64, frame[sequence_offset .. sequence_offset + 8], notice.value.sequence, .big);
                @memcpy(frame[binary_header_size..], chunk);
                return .{ .kind = .binary, .payload = frame };
            },
        }
    }

    pub fn sendTransferChunk(
        self: *DeviceTransport,
        transfer_id: [16]u8,
        sequence: u64,
        payload: []const u8,
    ) !void {
        switch (self.*) {
            .websocket => |*connection| {
                const frame = try connection.allocator.alloc(u8, binary_header_size + payload.len);
                defer connection.allocator.free(frame);
                @memcpy(frame[0..binary_magic.len], binary_magic);
                @memcpy(frame[binary_magic.len .. binary_magic.len + transfer_id.len], &transfer_id);
                const sequence_offset = binary_magic.len + transfer_id.len;
                std.mem.writeInt(u64, frame[sequence_offset .. sequence_offset + 8], sequence, .big);
                @memcpy(frame[binary_header_size..], payload);
                try connection.writeBinary(frame);
            },
            .http => |*connection| try connection.sendTransferChunk(transfer_id, sequence, payload),
        }
    }

    pub fn finishReceivedTransferChunk(self: *DeviceTransport, success: bool) !void {
        switch (self.*) {
            .websocket => {},
            .http => |*connection| try connection.finishTransferChunk(success),
        }
    }
};

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

test "gateway URL selects transport from scheme" {
    try std.testing.expectEqual(Kind.websocket, try DeviceTransport.kindForURL("ws://localhost/device/ws"));
    try std.testing.expectEqual(Kind.websocket, try DeviceTransport.kindForURL("wss://example.com/device/ws"));
    try std.testing.expectEqual(Kind.http, try DeviceTransport.kindForURL("http://localhost/device/http"));
    try std.testing.expectEqual(Kind.http, try DeviceTransport.kindForURL("https://example.com/device/http"));
    try std.testing.expectError(error.UnsupportedGatewayScheme, DeviceTransport.kindForURL("ftp://example.com"));
}
