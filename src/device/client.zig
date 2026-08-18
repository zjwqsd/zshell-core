const std = @import("std");
const builtin = @import("builtin");

const dispatcher = @import("../protocol/dispatcher.zig");
const events = @import("../control/events.zig");
const version = @import("../version.zig");
const transfer = @import("transfer.zig");
const transport = @import("transport.zig");

const protocol_version: u32 = 3;
const reconnect_delay_seconds: i64 = 2;

var lifecycle_mutex: std.Io.Mutex = .init;
var stop_requested: bool = false;
var active_connection: ?*transport.DeviceTransport = null;

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

fn setActiveConnection(io: std.Io, connection: ?*transport.DeviceTransport) bool {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    if (stop_requested) return false;
    active_connection = connection;
    return true;
}

fn clearActiveConnection(io: std.Io, connection: *transport.DeviceTransport) void {
    lifecycle_mutex.lockUncancelable(io);
    defer lifecycle_mutex.unlock(io);
    if (active_connection == connection) active_connection = null;
}

const Config = struct {
    gateway_url: []const u8,
    token: []const u8,
    device_name: []const u8,
    transport_kind: transport.Kind,

    fn load(environ_map: anytype) !Config {
        const gateway_url = environ_map.get("ZSHELL_GATEWAY_URL") orelse return error.MissingGatewayURL;
        if (!isAllowedGatewayURL(gateway_url)) return error.InvalidGatewayURL;
        const transport_kind = try transport.DeviceTransport.kindForURL(gateway_url);

        const token = environ_map.get("ZSHELL_DEVICE_TOKEN") orelse return error.MissingDeviceToken;
        if (token.len < 24 or token.len > 512) return error.InvalidDeviceToken;

        const device_name = environ_map.get("ZSHELL_DEVICE_NAME") orelse return error.MissingDeviceName;
        if (device_name.len == 0 or device_name.len > 128) return error.InvalidDeviceName;

        return .{
            .gateway_url = gateway_url,
            .token = token,
            .device_name = device_name,
            .transport_kind = transport_kind,
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

    const transport_name = @tagName(config.transport_kind);
    std.log.info("zshell transport: {s}", .{transport_name});
    std.log.info("zshell gateway: {s}", .{config.gateway_url});
    events.record(io, .system, "shellcore.transport", .shellcore, null, transport_name);
    events.record(io, .system, "shellcore.gateway_configured", .shellcore, null, config.gateway_url);
    if (std.mem.startsWith(u8, config.gateway_url, "ws://") or std.mem.startsWith(u8, config.gateway_url, "http://")) {
        events.record(io, .system, "shellcore.gateway_insecure", .shellcore, null, "unencrypted gateway transport");
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
    var connection = try transport.DeviceTransport.connect(allocator, io, config.gateway_url, config.token);
    defer connection.deinit();
    if (!setActiveConnection(io, &connection)) return error.StopRequested;
    defer clearActiveConnection(io, &connection);

    try sendHello(allocator, io, &connection, config);

    const ack_message = try connection.readMessage(allocator);
    defer allocator.free(ack_message.payload);
    if (ack_message.kind != .text) return error.ExpectedHelloAck;
    const ack = try std.json.parseFromSlice(
        HelloAck,
        allocator,
        ack_message.payload,
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

    var connection_writer = ConnectionWriter{ .transport = &connection };
    var transfers = transfer.Manager.init(allocator, io, &connection);
    defer transfers.deinit();

    while (true) {
        const frame = try connection.readMessage(allocator);
        defer allocator.free(frame.payload);

        if (frame.kind == .binary) {
            const accepted = transfers.handleBinary(frame.payload) catch |err| accepted: {
                events.record(io, .system, "transfer.frame_rejected", .shellcore, null, @errorName(err));
                break :accepted false;
            };
            try connection.finishReceivedTransferChunk(accepted);
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
    transport: *transport.DeviceTransport,

    fn sendPong(self: *ConnectionWriter, allocator: std.mem.Allocator, id: u64) !void {
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(.{ .type = "pong", .id = id }, .{})});
        try self.transport.writeText(payload.written());
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
        try self.transport.writeText(payload.written());
    }
};

fn sendHello(
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *transport.DeviceTransport,
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
    try connection.writeText(payload.written());
}

fn isAllowedGatewayURL(value: []const u8) bool {
    inline for (.{ "wss://", "ws://", "https://", "http://" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return value.len > prefix.len;
    }
    return false;
}
