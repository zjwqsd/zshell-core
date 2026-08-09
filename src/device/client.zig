const std = @import("std");
const builtin = @import("builtin");

const dispatcher = @import("../protocol/dispatcher.zig");
const events = @import("../control/events.zig");
const version = @import("../version.zig");

const protocol_version: u32 = 1;
const max_frame_size: usize = 16 * 1024 * 1024;
const reconnect_delay_seconds: i64 = 2;
const stream_buffer_size: usize = 16 * 1024;

const Config = struct {
    gateway: std.Io.net.IpAddress,
    gateway_text: []const u8,
    token: []const u8,
    device_name: []const u8,

    fn load(environ_map: anytype) !Config {
        const gateway_text = environ_map.get("ZSHELL_GATEWAY_ADDR") orelse "127.0.0.1:8767";
        const token = environ_map.get("ZSHELL_DEVICE_TOKEN") orelse return error.MissingDeviceToken;
        if (token.len < 24 or token.len > 512) return error.InvalidDeviceToken;

        const device_name = environ_map.get("ZSHELL_DEVICE_NAME") orelse "shellcore";
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

    try sendHello(allocator, &stream_writer.interface, config);

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

    while (true) {
        const frame = try readFrame(allocator, &stream_reader.interface);
        defer allocator.free(frame);
        try handleFrame(allocator, io, &stream_writer.interface, frame);
    }
}

fn sendHello(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    config: Config,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();

    try payload.writer.print("{f}", .{std.json.fmt(.{
        .type = "hello",
        .protocol = protocol_version,
        .token = config.token,
        .device = .{
            .name = config.device_name,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .version = version.value,
        },
    }, .{})});
    try writeFrame(writer, payload.written());
}

fn handleFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    frame: []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(
        Incoming,
        allocator,
        frame,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed.deinit();

    const message = parsed.value;
    if (std.mem.eql(u8, message.type, "ping")) {
        return writePong(allocator, writer, message.id);
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

    try writeResult(allocator, writer, message.id, response_writer.written());
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
