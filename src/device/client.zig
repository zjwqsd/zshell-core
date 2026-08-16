const std = @import("std");
const builtin = @import("builtin");

const dispatcher = @import("../protocol/dispatcher.zig");
const events = @import("../control/events.zig");
const version = @import("../version.zig");
const transfer = @import("transfer.zig");
const websocket = @import("websocket_client.zig");

const protocol_version: u32 = 3;
const reconnect_delay_seconds: i64 = 2;

var lifecycle_mutex: std.Io.Mutex = .init;
var stop_requested: bool = false;
var active_connection: ?*websocket.Connection = null;

pub fn requestStop(io: std.Io) void {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    stop_requested = true;
    if (active_connection) |connection| connection.interrupt();
}

fn resetStop(io: std.Io) void {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    stop_requested = false;
    active_connection = null;
}

fn shouldStop(io: std.Io) bool {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    return stop_requested;
}

fn setActiveConnection(io: std.Io, connection: ?*websocket.Connection) bool {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    if (stop_requested) return false;
    active_connection = connection;
    return true;
}

fn clearActiveConnection(io: std.Io, connection: *websocket.Connection) void {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    if (active_connection == connection) active_connection = null;
}

const Config = struct {
    gateway_url: []const u8,
    token: []const u8,
    device_name: []const u8,

    fn load(environ_map: anytype) !Config {
        const gateway_url = environ_map.get("ZSHELL_GATEWAY_URL") orelse return error.MissingGatewayURL;
        if (!isAllowedGatewayURL(gateway_url)) return error.InvalidGatewayURL;

        const token = environ_map.get("ZSHELL_DEVICE_TOKEN") orelse return error.MissingDeviceToken;
        if (token.len < 24 or token.len > 512) return error.InvalidDeviceToken;

        const device_name = environ_map.get("ZSHELL_DEVICE_NAME") orelse return error.MissingDeviceName;
        if (device_name.len == 0 or device_name.len > 128) return error.InvalidDeviceName;

        return .{
            .gateway_url = gateway_url,
            .token = token,
            .device_name = device_name,
        };
    }
};

const Incoming = struct {
    type: []const u8,
    id: u64,
    operation: ?[]const u8 = null,
    arguments: ?std.json.Value = null,
};

const HelloAck = struct {
    type: []const u8,
    accepted: bool,
    message: ?[]const u8 = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: anytype,
) !void {
    const config = try Config.load(environ_map);
    resetStop(io);
    events.record(io, .system, "shellcore.gateway_configured", .shellcore, null, config.gateway_url);
    if (std.mem.startsWith(u8, config.gateway_url, "ws://")) {
        events.record(io, .system, "shellcore.gateway_insecure", .shellcore, null, "unencrypted ws:// transport");
    }

    while (!shouldStop(io)) {
        connectAndServe(allocator, io, config) catch |err| {
            if (shouldStop(io)) return;
            events.record(
                io,
                .system,
                "shellcore.gateway_disconnected",
                .shellcore,
                null,
                @errorName(err),
            );
        };
        if (shouldStop(io)) return;
        try io.sleep(.fromSeconds(reconnect_delay_seconds), .awake);
    }
}

fn connectAndServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
) !void {
    var socket = try websocket.Connection.connect(allocator, io, config.gateway_url, config.token);
    defer socket.deinit();
    if (!setActiveConnection(io, &socket)) return error.StopRequested;
    defer clearActiveConnection(io, &socket);

    try sendHello(allocator, io, &socket, config);

    const ack_text = try socket.readText();
    defer allocator.free(ack_text);
    const ack = try std.json.parseFromSlice(
        HelloAck,
        allocator,
        ack_text,
        .{ .ignore_unknown_fields = false },
    );
    defer ack.deinit();

    if (!std.mem.eql(u8, ack.value.type, "hello_ack") or !ack.value.accepted) {
        if (ack.value.message) |message| {
            events.record(io, .system, "shellcore.gateway_rejected", .shellcore, null, message);
        }
        return error.GatewayRejected;
    }

    events.record(
        io,
        .system,
        "shellcore.gateway_connected",
        .shellcore,
        null,
        config.gateway_url,
    );

    var connection_writer = ConnectionWriter{
        .socket = &socket,
    };
    var transfers = transfer.Manager.init(allocator, io, &socket);
    defer transfers.deinit();

    while (true) {
        const frame = try socket.readMessage();
        defer allocator.free(frame.payload);

        if (frame.kind == .binary) {
            transfers.handleBinary(frame.payload) catch |err| {
                events.record(io, .system, "transfer.frame_rejected", .shellcore, null, @errorName(err));
            };
            continue;
        }
        if (try transfers.handleText(frame.payload)) continue;

        const parsed = try std.json.parseFromSlice(
            Incoming,
            allocator,
            frame.payload,
            .{ .ignore_unknown_fields = false },
        );
        defer parsed.deinit();

        const message = parsed.value;
        if (std.mem.eql(u8, message.type, "ping")) {
            try connection_writer.sendPong(allocator, message.id);
            continue;
        }
        if (!std.mem.eql(u8, message.type, "call")) {
            return error.UnsupportedGatewayMessage;
        }

        var request_writer: std.Io.Writer.Allocating = .init(allocator);
        defer request_writer.deinit();
        try request_writer.writer.print("{f}", .{std.json.fmt(.{
            .operation = message.operation orelse "",
            .arguments = message.arguments,
        }, .{ .emit_null_optional_fields = false })});

        var response_writer: std.Io.Writer.Allocating = .init(allocator);
        defer response_writer.deinit();
        _ = try dispatcher.dispatch(
            allocator,
            io,
            request_writer.written(),
            &response_writer.writer,
        );

        try connection_writer.sendResult(
            allocator,
            message.id,
            response_writer.written(),
        );
    }
}

const ConnectionWriter = struct {
    socket: *websocket.Connection,

    fn sendPong(self: *ConnectionWriter, allocator: std.mem.Allocator, id: u64) !void {
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(.{ .type = "pong", .id = id }, .{})});
        try self.socket.writeText(payload.written());
    }

    fn sendResult(
        self: *ConnectionWriter,
        allocator: std.mem.Allocator,
        id: u64,
        result: []const u8,
    ) !void {
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try payload.writer.writeAll("{\"type\":\"result\",\"id\":");
        try payload.writer.print("{d}", .{id});
        try payload.writer.writeAll(",\"payload\":");
        try payload.writer.writeAll(result);
        try payload.writer.writeAll("}");
        try self.socket.writeText(payload.written());
    }
};

fn sendHello(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket: *websocket.Connection,
    config: Config,
) !void {
    const workspace = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(workspace);

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.print("{f}", .{std.json.fmt(.{
        .type = "hello",
        .protocol = protocol_version,
        .device = .{
            .name = config.device_name,
            .workspace = workspace,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .version = version.value,
        },
    }, .{})});
    try socket.writeText(payload.written());
}

fn isAllowedGatewayURL(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "wss://")) return value.len > "wss://".len;
    if (std.mem.startsWith(u8, value, "ws://")) return value.len > "ws://".len;
    return false;
}
