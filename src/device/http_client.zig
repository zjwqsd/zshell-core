const std = @import("std");

const max_control_message_size: usize = 8 * 1024 * 1024;
const max_transfer_chunk_size: usize = 4 * 1024 * 1024;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    token: []const u8,
    session_id: ?[]u8 = null,
    pending_hello_ack: ?[]u8 = null,
    pending_chunk_ack: ?ChunkAck = null,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const ChunkAck = struct {
        transfer_id: [32]u8,
        sequence: u64,
    };

    const ResponseData = struct {
        status: std.http.Status,
        body: []u8,
        session_id: ?[]u8 = null,

        fn deinit(self: *ResponseData, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            if (self.session_id) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        token: []const u8,
    ) !Connection {
        const uri = try std.Uri.parse(url);
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
            return error.UnsupportedHttpScheme;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .base_url = url,
            .token = token,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.session_id) |value| self.allocator.free(value);
        if (self.pending_hello_ack) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn interrupt(self: *Connection) void {
        self.stopped.store(true, .release);
    }

    pub fn writeText(self: *Connection, payload: []const u8) !void {
        if (self.session_id == null) {
            var response = try self.request(.POST, self.base_url, "application/json", payload, max_control_message_size, true);
            errdefer response.deinit(self.allocator);
            if (response.status != .ok) return error.HttpHelloRejected;
            const session_id = response.session_id orelse return error.MissingHttpSessionID;
            response.session_id = null;
            self.session_id = session_id;
            self.pending_hello_ack = response.body;
            return;
        }

        const url = try self.endpoint("message", null);
        defer self.allocator.free(url);
        var response = try self.request(.POST, url, "application/json", payload, 4096, false);
        defer response.deinit(self.allocator);
        if (response.status != .no_content) return error.HttpMessageRejected;
    }

    pub fn readControl(self: *Connection) ![]u8 {
        if (self.pending_hello_ack) |payload| {
            self.pending_hello_ack = null;
            return payload;
        }
        while (!self.stopped.load(.acquire)) {
            const url = try self.endpoint("poll", null);
            defer self.allocator.free(url);
            var response = try self.request(.GET, url, null, &.{}, max_control_message_size, false);
            if (response.status == .no_content) {
                response.deinit(self.allocator);
                continue;
            }
            if (response.status == .gone) {
                response.deinit(self.allocator);
                return error.HttpDeviceSessionGone;
            }
            if (response.status != .ok) {
                response.deinit(self.allocator);
                return error.HttpPollRejected;
            }
            if (response.session_id) |value| self.allocator.free(value);
            return response.body;
        }
        return error.HttpTransportInterrupted;
    }

    pub fn sendTransferChunk(
        self: *Connection,
        transfer_id: [16]u8,
        sequence: u64,
        payload: []const u8,
    ) !void {
        const id_text = std.fmt.bytesToHex(transfer_id, .lower);
        const suffix = try std.fmt.allocPrint(self.allocator, "transfer/{s}/chunk/{d}", .{ &id_text, sequence });
        defer self.allocator.free(suffix);
        const url = try self.endpoint(suffix, null);
        defer self.allocator.free(url);
        var response = try self.request(.POST, url, "application/octet-stream", payload, 4096, false);
        defer response.deinit(self.allocator);
        if (response.status != .no_content) return error.HttpTransferChunkRejected;
    }

    pub fn downloadTransferChunk(
        self: *Connection,
        transfer_id_text: []const u8,
        sequence: u64,
    ) ![]u8 {
        if (self.pending_chunk_ack != null) return error.HttpTransferChunkAckPending;
        if (transfer_id_text.len != 32) return error.InvalidTransferId;
        var id_text: [32]u8 = undefined;
        @memcpy(&id_text, transfer_id_text);

        const suffix = try std.fmt.allocPrint(self.allocator, "transfer/{s}/chunk/{d}", .{ transfer_id_text, sequence });
        defer self.allocator.free(suffix);
        const url = try self.endpoint(suffix, null);
        defer self.allocator.free(url);
        var response = try self.request(.GET, url, null, &.{}, max_transfer_chunk_size, false);
        if (response.status != .ok) {
            response.deinit(self.allocator);
            return error.HttpTransferChunkDownloadRejected;
        }
        if (response.session_id) |value| self.allocator.free(value);
        self.pending_chunk_ack = .{ .transfer_id = id_text, .sequence = sequence };
        return response.body;
    }

    pub fn finishTransferChunk(self: *Connection, success: bool) !void {
        const ack = self.pending_chunk_ack orelse return;
        const suffix = try std.fmt.allocPrint(
            self.allocator,
            "transfer/{s}/chunk/{d}/ack?ok={d}",
            .{ &ack.transfer_id, ack.sequence, @intFromBool(success) },
        );
        defer self.allocator.free(suffix);
        const url = try self.endpoint(suffix, null);
        defer self.allocator.free(url);
        var response = try self.request(.POST, url, "application/json", &.{}, 4096, false);
        defer response.deinit(self.allocator);
        if (response.status != .no_content) return error.HttpTransferChunkAckRejected;
        self.pending_chunk_ack = null;
    }

    fn endpoint(self: *Connection, suffix: []const u8, query: ?[]const u8) ![]u8 {
        const session = self.session_id orelse return error.HttpSessionNotEstablished;
        if (query) |value| {
            return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}?{s}", .{ std.mem.trimEnd(u8, self.base_url, "/"), session, suffix, value });
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, self.base_url, "/"), session, suffix });
    }

    fn request(
        self: *Connection,
        method: std.http.Method,
        url: []const u8,
        content_type: ?[]const u8,
        body: []const u8,
        max_response_body: usize,
        capture_session: bool,
    ) !ResponseData {
        if (self.stopped.load(.acquire)) return error.HttpTransportInterrupted;

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        const authorization = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token});
        defer self.allocator.free(authorization);

        var extra_headers: [1]std.http.Header = undefined;
        var extra_headers_slice: []const std.http.Header = &.{};
        if (content_type) |value| {
            extra_headers[0] = .{ .name = "content-type", .value = value };
            extra_headers_slice = &extra_headers;
        }

        var req = try client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .authorization = .{ .override = authorization } },
            .extra_headers = extra_headers_slice,
        });
        defer req.deinit();

        if (method.requestHasBody()) {
            try req.sendBodyComplete(@constCast(body));
        } else {
            try req.sendBodiless();
        }
        var response = try req.receiveHead(&.{});

        var session_id: ?[]u8 = null;
        if (capture_session) {
            var it = response.head.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "x-zshell-session-id")) {
                    session_id = try self.allocator.dupe(u8, std.mem.trim(u8, header.value, " \t"));
                    break;
                }
            }
        }
        errdefer if (session_id) |value| self.allocator.free(value);

        const status = response.head.status;
        const response_body = if (status == .no_content or status == .not_modified or status.class() == .informational or method == .HEAD)
            try self.allocator.alloc(u8, 0)
        else body: {
            var transfer_buffer: [8192]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            const bytes = try reader.allocRemaining(self.allocator, .limited(max_response_body + 1));
            if (bytes.len > max_response_body) {
                self.allocator.free(bytes);
                return error.HttpResponseTooLarge;
            }
            break :body bytes;
        };
        errdefer self.allocator.free(response_body);

        return .{
            .status = status,
            .body = response_body,
            .session_id = session_id,
        };
    }
};
