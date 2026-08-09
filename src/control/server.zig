const std = @import("std");

const control = @import("state.zig");
const events = @import("events.zig");
const executions = @import("../executions/manager.zig");
const jobs = @import("../tools/jobs.zig");
const shells = @import("../tools/shells.zig");
const ports = @import("../runtime/ports.zig");
const version = @import("../version.zig");

pub const port: u16 = ports.human;
const connection_buffer_size: usize = 16 * 1024;
const dashboard_html = @embedFile("../web/index.html");

const PublicJob = struct {
    jobId: u64,
    command: []const u8,
    cwd: ?[]const u8,
    status: []const u8,
    exitCode: ?u8,
    terminationSource: ?[]const u8,
};

const PublicShell = struct {
    shellId: u64,
    initialCwd: ?[]const u8,
    status: []const u8,
    exitCode: ?u8,
    terminationSource: ?[]const u8,
};

pub fn serve(allocator: std.mem.Allocator, io: std.Io) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.log.info("zshell human control listening on http://127.0.0.1:{d}", .{port});
    events.record(io, .system, "control.server_started", .control, null, "human control plane listening");

    while (true) {
        var stream = try listener.accept(io);
        defer stream.close(io);

        var receive_buffer: [connection_buffer_size]u8 = undefined;
        var send_buffer: [connection_buffer_size]u8 = undefined;
        var connection_reader = stream.reader(io, &receive_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(
            &connection_reader.interface,
            &connection_writer.interface,
        );

        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            error.HttpHeadersInvalid, error.HttpHeadersOversize => {
                std.log.warn("rejected malformed human-control request: {s}", .{@errorName(err)});
                continue;
            },
            else => return err,
        };

        handleRequest(allocator, io, &request) catch |err| {
            std.log.err("human-control request failed: {s}", .{@errorName(err)});
            return err;
        };
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) !void {
    const origin = requestOriginStatus(request);
    if (origin == .denied or (request.head.method == .POST and origin != .allowed)) {
        return respondJsonValue(request, allocator, .forbidden, .{
            .@"error" = "HumanBrowserOriginRequired",
        });
    }

    const target = request.head.target;

    if (std.mem.eql(u8, target, "/")) {
        if (request.head.method != .GET) return methodNotAllowed(request, allocator);
        return request.respond(dashboard_html, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{
                    .name = "content-type",
                    .value = "text/html; charset=utf-8",
                },
                .{
                    .name = "cache-control",
                    .value = "no-store",
                },
                .{
                    .name = "content-security-policy",
                    .value = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; object-src 'none'; base-uri 'none'",
                },
            },
        });
    }

    if (std.mem.eql(u8, target, "/healthz")) {
        if (request.head.method != .GET) return methodNotAllowed(request, allocator);
        return respondJsonValue(request, allocator, .ok, .{ .status = "ok" });
    }

    if (std.mem.eql(u8, target, "/api/state")) {
        if (request.head.method != .GET) return methodNotAllowed(request, allocator);
        return respondState(allocator, io, request);
    }

    if (std.mem.eql(u8, target, "/api/control/take")) {
        if (request.head.method != .POST) return methodNotAllowed(request, allocator);
        const before = control.snapshot(io);
        const after = control.take(io);
        if (before.owner != after.owner) {
            events.record(io, .human, "control.taken", .control, null, "new Agent mutations blocked; running work unchanged");
        }
        return respondControl(allocator, request, after);
    }

    if (std.mem.eql(u8, target, "/api/control/release")) {
        if (request.head.method != .POST) return methodNotAllowed(request, allocator);
        const before = control.snapshot(io);
        const after = control.release(io);
        if (before.owner != after.owner) {
            events.record(io, .human, "control.released", .control, null, "Agent execution control restored");
        }
        return respondControl(allocator, request, after);
    }

    if (request.head.method == .POST) {
        if (parseActionId(target, "/api/executions/", "/terminate")) |id| {
            if (!control.humanHasControl(io)) return humanControlRequired(request, allocator);
            executions.requestTerminate(io, id, .human) catch |err| switch (err) {
                error.ExecutionNotFound => return notFound(request, allocator, "ExecutionNotFound"),
            };
            return respondJsonValue(request, allocator, .ok, .{
                .executionId = id,
                .terminationRequested = true,
                .terminationSource = "human",
            });
        }

        if (parseActionId(target, "/api/jobs/", "/stop")) |id| {
            if (!control.humanHasControl(io)) return humanControlRequired(request, allocator);
            const result = jobs.stopBy(id, .human) catch |err| switch (err) {
                error.JobNotFound => return notFound(request, allocator, "JobNotFound"),
            };
            return respondJsonValue(request, allocator, .ok, .{
                .jobId = result.job_id,
                .status = result.status.name(),
                .termination = result.termination,
                .terminationSource = if (result.termination_source) |source| source.name() else null,
            });
        }

        if (parseActionId(target, "/api/shells/", "/kill")) |id| {
            if (!control.humanHasControl(io)) return humanControlRequired(request, allocator);
            const result = shells.killBy(id, .human) catch |err| switch (err) {
                error.ShellNotFound => return notFound(request, allocator, "ShellNotFound"),
            };
            return respondJsonValue(request, allocator, .ok, .{
                .shellId = result.shell_id,
                .status = result.status.name(),
                .termination = result.termination,
                .terminationSource = if (result.termination_source) |source| source.name() else null,
            });
        }
    }

    return notFound(request, allocator, "NotFound");
}

fn respondState(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) !void {
    const control_snapshot = control.snapshot(io);

    const active_executions = try executions.list(allocator, io);
    defer active_executions.deinit(allocator);

    const job_list = try jobs.list(allocator);
    defer job_list.deinit(allocator);
    const public_jobs = try allocator.alloc(PublicJob, job_list.items.len);
    defer allocator.free(public_jobs);
    for (job_list.items, public_jobs) |job, *public| {
        public.* = .{
            .jobId = job.job_id,
            .command = job.command,
            .cwd = job.cwd,
            .status = job.status.name(),
            .exitCode = job.exit_code,
            .terminationSource = if (job.termination_source) |source| source.name() else null,
        };
    }

    const shell_list = try shells.list(allocator);
    defer shell_list.deinit(allocator);
    const public_shells = try allocator.alloc(PublicShell, shell_list.items.len);
    defer allocator.free(public_shells);
    for (shell_list.items, public_shells) |shell, *public| {
        public.* = .{
            .shellId = shell.shell_id,
            .initialCwd = shell.initial_cwd,
            .status = shell.status.name(),
            .exitCode = shell.exit_code,
            .terminationSource = if (shell.termination_source) |source| source.name() else null,
        };
    }

    const event_snapshot = try events.snapshotRecent(allocator, io, 200);
    defer event_snapshot.deinit(allocator);

    return respondJsonValue(request, allocator, .ok, .{
        .service = .{
            .status = "running",
            .version = version.value,
            .humanPort = port,
        },
        .control = .{
            .owner = control_snapshot.owner.name(),
            .canAgentExecute = control_snapshot.canAgentExecute(),
            .generation = control_snapshot.generation,
        },
        .executions = active_executions.items,
        .jobs = public_jobs,
        .shells = public_shells,
        .events = event_snapshot.items,
    });
}

fn respondControl(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    snapshot: control.Snapshot,
) !void {
    return respondJsonValue(request, allocator, .ok, .{
        .owner = snapshot.owner.name(),
        .canAgentExecute = snapshot.canAgentExecute(),
        .generation = snapshot.generation,
    });
}

fn respondJsonValue(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    status: std.http.Status,
    value: anytype,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try output.writer.print("{f}", .{
        std.json.fmt(value, .{ .emit_null_optional_fields = false }),
    });

    try request.respond(output.written(), .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "application/json; charset=utf-8",
            },
            .{
                .name = "cache-control",
                .value = "no-store",
            },
        },
    });
}

fn humanControlRequired(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
) !void {
    return respondJsonValue(request, allocator, .conflict, .{
        .@"error" = "HumanControlRequired",
        .message = "Take control before terminating Agent resources.",
    });
}

fn notFound(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    name: []const u8,
) !void {
    return respondJsonValue(request, allocator, .not_found, .{ .@"error" = name });
}

fn methodNotAllowed(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
) !void {
    return respondJsonValue(request, allocator, .method_not_allowed, .{
        .@"error" = "MethodNotAllowed",
    });
}

fn parseActionId(target: []const u8, prefix: []const u8, suffix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    if (!std.mem.endsWith(u8, target, suffix)) return null;
    if (target.len <= prefix.len + suffix.len) return null;

    const id_text = target[prefix.len .. target.len - suffix.len];
    const id = std.fmt.parseInt(u64, id_text, 10) catch return null;
    return if (id == 0) null else id;
}

const OriginStatus = enum { none, allowed, denied };

fn requestOriginStatus(request: *const std.http.Server.Request) OriginStatus {
    var seen = false;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "Origin")) continue;
        if (seen) return .denied;
        seen = true;

        if (!std.mem.eql(u8, header.value, "http://127.0.0.1:8766") and
            !std.mem.eql(u8, header.value, "http://localhost:8766"))
        {
            return .denied;
        }
    }
    return if (seen) .allowed else .none;
}

test "human control action path parser" {
    try std.testing.expectEqual(@as(?u64, 42), parseActionId(
        "/api/jobs/42/stop",
        "/api/jobs/",
        "/stop",
    ));
    try std.testing.expect(parseActionId("/api/jobs/0/stop", "/api/jobs/", "/stop") == null);
    try std.testing.expect(parseActionId("/api/jobs/nope/stop", "/api/jobs/", "/stop") == null);
}
