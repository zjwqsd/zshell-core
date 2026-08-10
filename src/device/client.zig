const std = @import("std");
const builtin = @import("builtin");

const dispatcher = @import("../protocol/dispatcher.zig");
const events = @import("../control/events.zig");
const version = @import("../version.zig");
const websocket = @import("websocket_client.zig");

const protocol_version: u32 = 2;
const reconnect_delay_seconds: i64 = 2;
const max_concurrent_calls: usize = 32;

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

    std.log.info("zshell ShellCore WebSocket gateway: {s}", .{config.gateway_url});
    if (std.mem.startsWith(u8, config.gateway_url, "ws://")) {
        std.log.warn("ShellCore is using unencrypted ws:// transport; use this only on a trusted LAN", .{});
    }

    while (true) {
        connectAndServe(allocator, io, config) catch |err| {
            std.log.warn("ShellCore WebSocket session ended: {s}", .{@errorName(err)});
            events.record(
                io,
                .system,
                "shellcore.gateway_disconnected",
                .shellcore,
                null,
                @errorName(err),
            );
        };
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
            std.log.err("gateway rejected ShellCore: {s}", .{message});
        }
        return error.GatewayRejected;
    }

    std.log.info("ShellCore connected to WebSocket gateway {s}", .{config.gateway_url});
    events.record(
        io,
        .system,
        "shellcore.gateway_connected",
        .shellcore,
        null,
        config.gateway_url,
    );

    var connection_writer = ConnectionWriter{
        .io = io,
        .socket = &socket,
    };
    var call_slots = [_]CallSlot{.{}} ** max_concurrent_calls;
    defer joinAllCalls(&call_slots);

    while (true) {
        reapFinishedCalls(&call_slots);

        const frame = try socket.readText();
        defer allocator.free(frame);

        const parsed = try std.json.parseFromSlice(
            Incoming,
            allocator,
            frame,
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

        const slot = availableCallSlot(&call_slots) orelse {
            try connection_writer.sendBusyResult(allocator, message.id);
            continue;
        };

        var request_writer: std.Io.Writer.Allocating = .init(allocator);
        defer request_writer.deinit();
        try request_writer.writer.print("{f}", .{std.json.fmt(.{
            .operation = message.operation orelse "",
            .arguments = message.arguments,
        }, .{ .emit_null_optional_fields = false })});

        const request = try request_writer.toOwnedSlice();
        var request_owned = true;
        errdefer if (request_owned) allocator.free(request);

        slot.done.store(false, .release);
        const thread = try std.Thread.spawn(
            .{},
            callWorkerMain,
            .{CallWorkerContext{
                .allocator = allocator,
                .io = io,
                .connection_writer = &connection_writer,
                .request_id = message.id,
                .request = request,
                .done = &slot.done,
            }},
        );
        request_owned = false;
        slot.thread = thread;
    }
}

const ConnectionWriter = struct {
    io: std.Io,
    socket: *websocket.Connection,
    mutex: std.Io.Mutex = .init,

    fn sendPong(self: *ConnectionWriter, allocator: std.mem.Allocator, id: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try payload.writer.writeAll("{\"type\":\"result\",\"id\":");
        try payload.writer.print("{d}", .{id});
        try payload.writer.writeAll(",\"payload\":");
        try payload.writer.writeAll(result);
        try payload.writer.writeAll("}");
        try self.socket.writeText(payload.written());
    }

    fn sendBusyResult(self: *ConnectionWriter, allocator: std.mem.Allocator, id: u64) !void {
        var result: std.Io.Writer.Allocating = .init(allocator);
        defer result.deinit();
        try result.writer.print("{f}", .{std.json.fmt(.{
            .ok = false,
            .isError = true,
            .@"error" = .{
                .code = "TooManyConcurrentCalls",
                .message = "ShellCore has too many concurrent calls",
            },
        }, .{})});
        try self.sendResult(allocator, id, result.written());
    }
};

const CallSlot = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
};

const CallWorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    connection_writer: *ConnectionWriter,
    request_id: u64,
    request: []u8,
    done: *std.atomic.Value(bool),
};

fn callWorkerMain(context: CallWorkerContext) void {
    defer context.done.store(true, .release);
    defer context.allocator.free(context.request);

    runCallWorker(context) catch |err| {
        std.log.warn(
            "ShellCore call {d} worker failed: {s}",
            .{ context.request_id, @errorName(err) },
        );
        events.record(
            context.io,
            .system,
            "shellcore.call_worker_failed",
            .shellcore,
            context.request_id,
            @errorName(err),
        );
    };
}

fn runCallWorker(context: CallWorkerContext) !void {
    var response_writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer response_writer.deinit();

    _ = try dispatcher.dispatch(
        context.allocator,
        context.io,
        context.request,
        &response_writer.writer,
    );

    try context.connection_writer.sendResult(
        context.allocator,
        context.request_id,
        response_writer.written(),
    );
}

fn availableCallSlot(slots: *[max_concurrent_calls]CallSlot) ?*CallSlot {
    reapFinishedCalls(slots);
    for (slots) |*slot| {
        if (slot.thread == null) return slot;
    }
    return null;
}

fn reapFinishedCalls(slots: *[max_concurrent_calls]CallSlot) void {
    for (slots) |*slot| {
        const thread = slot.thread orelse continue;
        if (!slot.done.load(.acquire)) continue;
        thread.join();
        slot.thread = null;
        slot.done.store(false, .release);
    }
}

fn joinAllCalls(slots: *[max_concurrent_calls]CallSlot) void {
    for (slots) |*slot| {
        if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        }
    }
}

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
