const std = @import("std");
const builtin = @import("builtin");

const dispatcher = @import("../protocol/dispatcher.zig");
const events = @import("../control/events.zig");
const version = @import("../version.zig");

const protocol_version: u32 = 1;
const max_frame_size: usize = 16 * 1024 * 1024;
const reconnect_delay_seconds: i64 = 2;
const stream_buffer_size: usize = 16 * 1024;
const max_concurrent_calls: usize = 32;

const Config = struct {
    gateway: std.Io.net.IpAddress,
    gateway_text: []const u8,
    token: []const u8,
    device_name: []const u8,

    fn load(environ_map: anytype) !Config {
        const gateway_text = environ_map.get("ZSHELL_GATEWAY_ADDR") orelse "127.0.0.1:8767";
        const token = environ_map.get("ZSHELL_DEVICE_TOKEN") orelse return error.MissingDeviceToken;
        if (token.len < 24 or token.len > 512) return error.InvalidDeviceToken;

        const device_name = environ_map.get("ZSHELL_DEVICE_NAME") orelse return error.MissingDeviceName;
        if (device_name.len == 0 or device_name.len > 128) return error.InvalidDeviceName;

        const gateway = try parseGatewayAddress(gateway_text);
        return .{
            .gateway = gateway,
            .gateway_text = gateway_text,
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

    std.log.info("zshell ShellCore target gateway: {s}", .{config.gateway_text});
    while (true) {
        connectAndServe(allocator, io, config) catch |err| {
            std.log.warn("ShellCore gateway connection ended: {s}", .{@errorName(err)});
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
    var address = config.gateway;
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buffer: [stream_buffer_size]u8 = undefined;
    var write_buffer: [stream_buffer_size]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);

    try sendHello(allocator, io, &stream_writer.interface, config);

    const ack_text = try readFrame(allocator, &stream_reader.interface);
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

    std.log.info("ShellCore connected to gateway {s}", .{config.gateway_text});
    events.record(
        io,
        .system,
        "shellcore.gateway_connected",
        .shellcore,
        null,
        config.gateway_text,
    );

    // The reader must remain free to receive ping and additional calls while a
    // command is running. Call workers therefore execute dispatch independently,
    // while every write to the shared TCP stream is serialized here.
    var connection_writer = ConnectionWriter{
        .io = io,
        .writer = &stream_writer.interface,
    };
    var call_slots = [_]CallSlot{.{}} ** max_concurrent_calls;
    defer joinAllCalls(&call_slots);

    while (true) {
        reapFinishedCalls(&call_slots);

        const frame = try readFrame(allocator, &stream_reader.interface);
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
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,

    fn sendPong(
        self: *ConnectionWriter,
        allocator: std.mem.Allocator,
        id: u64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try writePong(allocator, self.writer, id);
    }

    fn sendResult(
        self: *ConnectionWriter,
        allocator: std.mem.Allocator,
        id: u64,
        result: []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try writeResult(allocator, self.writer, id, result);
    }

    fn sendBusyResult(
        self: *ConnectionWriter,
        allocator: std.mem.Allocator,
        id: u64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try payload.writer.print("{f}", .{std.json.fmt(.{
            .ok = false,
            .isError = true,
            .@"error" = .{
                .code = "TooManyConcurrentCalls",
                .message = "ShellCore has too many concurrent calls",
            },
        }, .{})});
        try writeResult(allocator, self.writer, id, payload.written());
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
    writer: *std.Io.Writer,
    config: Config,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();

    const workspace = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(workspace);

    try payload.writer.print("{f}", .{std.json.fmt(.{
        .type = "hello",
        .protocol = protocol_version,
        .token = config.token,
        .device = .{
            .name = config.device_name,
            .workspace = workspace,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .version = version.value,
        },
    }, .{})});
    try writeFrame(writer, payload.written());
}

fn writePong(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: u64,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"type\":\"pong\",\"id\":");
    try payload.writer.print("{d}", .{id});
    try payload.writer.writeAll("}");
    try writeFrame(writer, payload.written());
}

fn writeResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
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
    try writeFrame(writer, payload.written());
}

fn writeFrame(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len == 0 or payload.len > max_frame_size) return error.FrameTooLarge;
    const length: u32 = @intCast(payload.len);
    const header = [4]u8{
        @intCast((length >> 24) & 0xff),
        @intCast((length >> 16) & 0xff),
        @intCast((length >> 8) & 0xff),
        @intCast(length & 0xff),
    };
    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.flush();
}

fn readFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ![]u8 {
    var header: [4]u8 = undefined;
    try reader.readSliceAll(&header);
    const length_u32: u32 =
        (@as(u32, header[0]) << 24) |
        (@as(u32, header[1]) << 16) |
        (@as(u32, header[2]) << 8) |
        @as(u32, header[3]);
    const length: usize = @intCast(length_u32);
    if (length == 0 or length > max_frame_size) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try reader.readSliceAll(payload);
    return payload;
}

fn parseGatewayAddress(text: []const u8) !std.Io.net.IpAddress {
    const separator = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidGatewayAddress;
    if (separator == 0 or separator + 1 >= text.len) return error.InvalidGatewayAddress;

    const host = text[0..separator];
    const port = std.fmt.parseInt(u16, text[separator + 1 ..], 10) catch return error.InvalidGatewayAddress;
    return std.Io.net.IpAddress.parse(host, port) catch return error.InvalidGatewayAddress;
}
