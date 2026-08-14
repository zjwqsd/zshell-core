const std = @import("std");

const control = @import("../control/state.zig");
const browser_operations = @import("browser.zig");
const events = @import("../control/events.zig");
const environment = @import("../tools/environment.zig");
const exec = @import("../tools/exec.zig");
const executions = @import("../executions/manager.zig");
const jobs = @import("../tools/jobs.zig");
const file_operations = @import("files.zig");
const shells = @import("../tools/shells.zig");
const output = @import("output.zig");

pub const Outcome = enum {
    ok,
    bad_request,
    not_found,
};

const Request = struct {
    operation: []const u8,
    arguments: ?std.json.Value = null,
};

const ShellWriteArguments = struct {
    shellId: u64,
    input: []const u8,
    enter: bool = true,
};

const ShellResizeArguments = struct {
    shellId: u64,
    cols: u16,
    rows: u16,
};

const StreamReadArguments = struct {
    id: u64,
    stdout_after: ?u64 = null,
    stderr_after: ?u64 = null,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    request_text: []const u8,
    writer: *std.Io.Writer,
) !Outcome {
    const parsed = std.json.parseFromSlice(
        Request,
        allocator,
        request_text,
        .{ .ignore_unknown_fields = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeInvalidRequest(writer, "Invalid ShellCore request");
            return .bad_request;
        },
    };
    defer parsed.deinit();

    const request = parsed.value;
    if (request.operation.len == 0) {
        try writeInvalidRequest(writer, "operation must not be empty");
        return .bad_request;
    }

    if (isMutating(request.operation)) {
        control.requireAgent(io) catch |err| switch (err) {
            error.HumanControlActive => {
                events.record(
                    io,
                    .agent,
                    "shellcore.execute_rejected",
                    .shellcore,
                    null,
                    request.operation,
                );
                try writeFailureWithDetails(
                    writer,
                    "HumanControlActive",
                    "Human control is active. This operation was not started.",
                    .{
                        .controlOwner = "human",
                        .canExecute = false,
                    },
                );
                return .ok;
            },
        };
    }

    if (std.mem.eql(u8, request.operation, "environment_info")) {
        return environmentInfo(allocator, io, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "control_status")) {
        return controlStatus(io, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "exec")) {
        return execute(allocator, io, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "job_start")) {
        return jobStart(allocator, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "job_status")) {
        return jobStatus(request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "job_logs")) {
        return jobLogs(allocator, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "job_stop")) {
        return jobStop(request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "job_list")) {
        return jobList(allocator, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_start")) {
        return shellStart(allocator, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_write")) {
        return shellWrite(request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_read")) {
        return shellRead(allocator, request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_resize")) {
        return shellResize(request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_kill")) {
        return shellKill(request.arguments, writer);
    }
    if (std.mem.eql(u8, request.operation, "shell_list")) {
        return shellList(allocator, request.arguments, writer);
    }
    if (try browser_operations.dispatch(
        allocator,
        request.operation,
        request.arguments,
        writer,
    )) |browser_outcome| {
        return switch (browser_outcome) {
            .ok => .ok,
            .bad_request => .bad_request,
        };
    }

    if (try file_operations.dispatch(
        allocator,
        io,
        request.operation,
        request.arguments,
        writer,
    )) |file_outcome| {
        return switch (file_outcome) {
            .ok => .ok,
            .bad_request => .bad_request,
        };
    }

    try writeFailure(writer, "OperationNotFound", "Unknown ShellCore operation");
    return .not_found;
}

fn isMutating(operation: []const u8) bool {
    return std.mem.eql(u8, operation, "exec") or
        std.mem.eql(u8, operation, "job_start") or
        std.mem.eql(u8, operation, "job_stop") or
        std.mem.eql(u8, operation, "shell_start") or
        std.mem.eql(u8, operation, "shell_write") or
        std.mem.eql(u8, operation, "shell_resize") or
        std.mem.eql(u8, operation, "shell_kill") or
        std.mem.eql(u8, operation, "file_write") or
        std.mem.eql(u8, operation, "file_patch") or
        std.mem.eql(u8, operation, "file_mkdir") or
        std.mem.eql(u8, operation, "browser_start") or
        std.mem.eql(u8, operation, "browser_open") or
        std.mem.eql(u8, operation, "browser_click") or
        std.mem.eql(u8, operation, "browser_fill") or
        std.mem.eql(u8, operation, "browser_select") or
        std.mem.eql(u8, operation, "browser_check") or
        std.mem.eql(u8, operation, "browser_press") or
        std.mem.eql(u8, operation, "browser_upload") or
        std.mem.eql(u8, operation, "browser_download") or
        std.mem.eql(u8, operation, "browser_tabs") or
        std.mem.eql(u8, operation, "browser_screenshot") or
        std.mem.eql(u8, operation, "browser_takeover") or
        std.mem.eql(u8, operation, "browser_close");
}

fn environmentInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;

    const info = environment.collect(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeFailure(writer, @errorName(err), "Failed to collect environment information");
            return .ok;
        },
    };
    defer info.deinit(allocator);

    try writeSuccess(writer, .{
        .os = info.os,
        .arch = info.arch,
        .zigVersion = info.zig_version,
        .workspace = info.cwd,
    }, false);
    return .ok;
}

fn controlStatus(
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;

    const snapshot = control.snapshot(io);
    try writeSuccess(writer, .{
        .owner = snapshot.owner.name(),
        .canExecute = snapshot.canAgentExecute(),
        .generation = snapshot.generation,
    }, false);
    return .ok;
}

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseExecInput(arguments, writer) orelse {
        return .bad_request;
    };

    exec.validate(input) catch |err| switch (err) {
        error.EmptyCommand => {
            try writeInvalidRequest(writer, "command must not be empty");
            return .bad_request;
        },
        error.InvalidTimeout => {
            try writeInvalidRequest(writer, "timeoutMs is outside the allowed range");
            return .bad_request;
        },
    };

    const tracked = executions.run(allocator, io, input) catch |err| {
        try writeFailure(writer, @errorName(err), "Execution could not be started");
        return .ok;
    };
    defer tracked.result.deinit(allocator);

    const stdout = try output.encode(allocator, tracked.result.stdout);
    defer stdout.deinit(allocator);
    const stderr = try output.encode(allocator, tracked.result.stderr);
    defer stderr.deinit(allocator);

    try writeSuccess(writer, .{
        .executionId = tracked.execution_id,
        .shell = exec.shell_name,
        .exitCode = tracked.result.exit_code,
        .termination = tracked.result.termination,
        .terminationSource = tracked.result.termination_source.name(),
        .timedOut = tracked.result.timed_out,
        .stdout = .{ .encoding = stdout.encoding, .data = stdout.data },
        .stderr = .{ .encoding = stderr.encoding, .data = stderr.data },
    }, !tracked.result.succeeded());
    return .ok;
}

fn jobStart(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    var args_storage: std.ArrayList([]const u8) = .empty;
    defer args_storage.deinit(allocator);
    const input = try parseJobStartInput(allocator, arguments, &args_storage, writer) orelse {
        return .bad_request;
    };

    const result = jobs.start(input) catch |err| {
        try writeFailure(writer, @errorName(err), "Job could not be started");
        return .ok;
    };

    try writeSuccess(writer, .{
        .jobId = result.job_id,
        .status = result.status.name(),
    }, false);
    return .ok;
}

fn jobStatus(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const job_id = try parseIdArgument(arguments, "jobId", writer) orelse {
        return .bad_request;
    };

    const result = jobs.status(job_id) catch |err| switch (err) {
        error.JobNotFound => {
            try writeFailure(writer, "JobNotFound", "Background job was not found");
            return .ok;
        },
    };

    try writeJobStatus(writer, result);
    return .ok;
}

fn jobStop(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const job_id = try parseIdArgument(arguments, "jobId", writer) orelse {
        return .bad_request;
    };

    const result = jobs.stop(job_id) catch |err| switch (err) {
        error.JobNotFound => {
            try writeFailure(writer, "JobNotFound", "Background job was not found");
            return .ok;
        },
    };

    try writeJobStatus(writer, result);
    return .ok;
}

fn writeJobStatus(writer: *std.Io.Writer, result: jobs.StatusResult) !void {
    try writeSuccess(writer, .{
        .jobId = result.job_id,
        .program = result.program,
        .args = result.args,
        .cwd = result.cwd,
        .status = result.status.name(),
        .exitCode = result.exit_code,
        .termination = result.termination,
        .terminationSource = if (result.termination_source) |source| source.name() else null,
        .workerError = result.worker_error,
        .stdoutBytes = result.stdout_bytes,
        .stderrBytes = result.stderr_bytes,
        .stdoutTruncated = result.stdout_truncated,
        .stderrTruncated = result.stderr_truncated,
    }, result.status == .failed);
}

fn jobLogs(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseStreamReadArguments(arguments, "jobId", writer) orelse {
        return .bad_request;
    };

    const result = jobs.logs(
        allocator,
        input.id,
        input.stdout_after,
        input.stderr_after,
    ) catch |err| switch (err) {
        error.JobNotFound => {
            try writeFailure(writer, "JobNotFound", "Background job was not found");
            return .ok;
        },
        error.CursorAheadOfStream => {
            try writeInvalidRequest(writer, "output cursor is ahead of the stream");
            return .bad_request;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    const stdout = try output.encode(allocator, result.stdout);
    defer stdout.deinit(allocator);
    const stderr = try output.encode(allocator, result.stderr);
    defer stderr.deinit(allocator);

    try writeSuccess(writer, .{
        .jobId = result.job_id,
        .stdout = .{
            .encoding = stdout.encoding,
            .data = stdout.data,
            .truncated = result.stdout_truncated,
            .startOffset = result.stdout_start_offset,
            .nextOffset = result.stdout_next_offset,
            .totalBytes = result.stdout_bytes,
        },
        .stderr = .{
            .encoding = stderr.encoding,
            .data = stderr.data,
            .truncated = result.stderr_truncated,
            .startOffset = result.stderr_start_offset,
            .nextOffset = result.stderr_next_offset,
            .totalBytes = result.stderr_bytes,
        },
    }, false);
    return .ok;
}

fn jobList(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;

    const result = try jobs.list(allocator);
    defer result.deinit(allocator);

    try writeSuccess(writer, .{ .jobs = result.items }, false);
    return .ok;
}

fn shellStart(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    var args_storage: std.ArrayList([]const u8) = .empty;
    defer args_storage.deinit(allocator);
    const input = try parseShellStartInput(allocator, arguments, &args_storage, writer) orelse {
        return .bad_request;
    };
    return startShell(input, writer);
}

fn startShell(
    input: shells.StartInput,
    writer: *std.Io.Writer,
) !Outcome {
    const result = shells.start(input) catch |err| {
        try writeFailure(writer, @errorName(err), "Persistent shell could not be started");
        return .ok;
    };

    try writeSuccess(writer, .{
        .shellId = result.shell_id,
        .shell = result.shell,
        .args = result.args,
        .initialCwd = result.initial_cwd,
        .cols = result.cols,
        .rows = result.rows,
        .status = result.status.name(),
        .backend = result.backend,
    }, false);
    return .ok;
}

fn shellWrite(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseShellWriteInput(arguments, writer) orelse {
        return .bad_request;
    };
    if (input.shellId == 0) {
        try writeInvalidRequest(writer, "shellId must be greater than zero");
        return .bad_request;
    }

    const result = shells.write(input.shellId, input.input, input.enter) catch |err| switch (err) {
        error.ShellNotFound => {
            try writeFailure(writer, "ShellNotFound", "Persistent shell was not found");
            return .ok;
        },
        error.ShellNotRunning => {
            try writeFailure(writer, "ShellNotRunning", "Persistent shell is not running");
            return .ok;
        },
        else => return err,
    };

    try writeSuccess(writer, .{
        .shellId = result.shell_id,
        .sentBytes = result.sent_bytes,
        .enter = result.enter,
    }, false);
    return .ok;
}

fn shellResize(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseShellResizeInput(arguments, writer) orelse {
        return .bad_request;
    };
    const result = shells.resize(input.shellId, input.cols, input.rows) catch |err| switch (err) {
        error.ShellNotFound => {
            try writeFailure(writer, "ShellNotFound", "Persistent shell was not found");
            return .ok;
        },
        error.ShellNotRunning => {
            try writeFailure(writer, "ShellNotRunning", "Persistent shell is not running");
            return .ok;
        },
        else => {
            try writeFailure(writer, @errorName(err), "Terminal could not be resized");
            return .ok;
        },
    };
    try writeSuccess(writer, .{
        .shellId = result.shell_id,
        .cols = result.cols,
        .rows = result.rows,
    }, false);
    return .ok;
}

fn shellRead(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseStreamReadArguments(arguments, "shellId", writer) orelse {
        return .bad_request;
    };

    const result = shells.read(
        allocator,
        input.id,
        input.stdout_after,
        input.stderr_after,
    ) catch |err| switch (err) {
        error.ShellNotFound => {
            try writeFailure(writer, "ShellNotFound", "Persistent shell was not found");
            return .ok;
        },
        error.CursorAheadOfStream => {
            try writeInvalidRequest(writer, "output cursor is ahead of the stream");
            return .bad_request;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    const stdout = try output.encode(allocator, result.stdout);
    defer stdout.deinit(allocator);
    const stderr = try output.encode(allocator, result.stderr);
    defer stderr.deinit(allocator);

    try writeSuccess(writer, .{
        .shellId = result.shell_id,
        .shell = result.shell,
        .args = result.args,
        .initialCwd = result.initial_cwd,
        .cols = result.cols,
        .rows = result.rows,
        .status = result.status.name(),
        .exitCode = result.exit_code,
        .termination = result.termination,
        .terminationSource = if (result.termination_source) |source| source.name() else null,
        .workerError = result.worker_error,
        .backend = shells.backend_name,
        .stdout = .{
            .encoding = stdout.encoding,
            .data = stdout.data,
            .truncated = result.stdout_truncated,
            .startOffset = result.stdout_start_offset,
            .nextOffset = result.stdout_next_offset,
            .totalBytes = result.stdout_bytes,
        },
        .stderr = .{
            .encoding = stderr.encoding,
            .data = stderr.data,
            .truncated = result.stderr_truncated,
            .startOffset = result.stderr_start_offset,
            .nextOffset = result.stderr_next_offset,
            .totalBytes = result.stderr_bytes,
        },
    }, result.status == .failed);
    return .ok;
}

fn shellKill(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const shell_id = try parseIdArgument(arguments, "shellId", writer) orelse {
        return .bad_request;
    };

    const result = shells.kill(shell_id) catch |err| switch (err) {
        error.ShellNotFound => {
            try writeFailure(writer, "ShellNotFound", "Persistent shell was not found");
            return .ok;
        },
    };

    try writeSuccess(writer, .{
        .shellId = result.shell_id,
        .status = result.status.name(),
        .exitCode = result.exit_code,
        .termination = result.termination,
        .terminationSource = if (result.termination_source) |source| source.name() else null,
        .workerError = result.worker_error,
    }, result.status == .failed);
    return .ok;
}

fn shellList(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;

    const result = try shells.list(allocator);
    defer result.deinit(allocator);

    const PublicItem = struct {
        shellId: u64,
        shell: []const u8,
        args: []const []const u8,
        initialCwd: ?[]const u8,
        cols: u16,
        rows: u16,
        status: []const u8,
        exitCode: ?u8,
        terminationSource: ?[]const u8,
    };

    const items = try allocator.alloc(PublicItem, result.items.len);
    defer allocator.free(items);
    for (result.items, items) |item, *public| {
        public.* = .{
            .shellId = item.shell_id,
            .shell = item.shell,
            .args = item.args,
            .initialCwd = item.initial_cwd,
            .cols = item.cols,
            .rows = item.rows,
            .status = item.status.name(),
            .exitCode = item.exit_code,
            .terminationSource = if (item.termination_source) |source| source.name() else null,
        };
    }

    try writeSuccess(writer, .{ .shells = items }, false);
    return .ok;
}

fn parseExecInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?exec.Input {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "exec requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "command", "cwd", "timeoutMs" })) {
                try writeInvalidRequest(writer, "Invalid exec arguments");
                break :blk null;
            }
            const command = getString(object, "command") orelse {
                try writeInvalidRequest(writer, "command must be a string");
                break :blk null;
            };
            const cwd = if (object.get("cwd")) |cwd_value| switch (cwd_value) {
                .string => |text| text,
                else => {
                    try writeInvalidRequest(writer, "cwd must be a string");
                    break :blk null;
                },
            } else null;
            const timeout_ms = if (object.get("timeoutMs")) |timeout_value| switch (timeout_value) {
                .integer => |number| blk_timeout: {
                    if (number <= 0) {
                        try writeInvalidRequest(writer, "timeoutMs is outside the allowed range");
                        break :blk null;
                    }
                    break :blk_timeout @as(u64, @intCast(number));
                },
                else => {
                    try writeInvalidRequest(writer, "timeoutMs must be an integer");
                    break :blk null;
                },
            } else exec.default_timeout_ms;

            break :blk exec.Input{
                .command = command,
                .cwd = cwd,
                .timeoutMs = timeout_ms,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseJobStartInput(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    args_storage: *std.ArrayList([]const u8),
    writer: *std.Io.Writer,
) !?jobs.StartInput {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "job_start requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "program", "args", "cwd" })) {
                try writeInvalidRequest(writer, "Invalid job_start arguments");
                break :blk null;
            }
            const program = getString(object, "program") orelse {
                try writeInvalidRequest(writer, "program must be a string");
                break :blk null;
            };
            if (program.len == 0) {
                try writeInvalidRequest(writer, "program must not be empty");
                break :blk null;
            }
            if (object.get("args")) |args_value| switch (args_value) {
                .array => |array| {
                    for (array.items) |arg_value| switch (arg_value) {
                        .string => |text| try args_storage.append(allocator, text),
                        else => {
                            try writeInvalidRequest(writer, "args must be an array of strings");
                            break :blk null;
                        },
                    };
                },
                else => {
                    try writeInvalidRequest(writer, "args must be an array of strings");
                    break :blk null;
                },
            };
            const cwd = if (object.get("cwd")) |cwd_value| switch (cwd_value) {
                .string => |text| text,
                else => {
                    try writeInvalidRequest(writer, "cwd must be a string");
                    break :blk null;
                },
            } else null;
            break :blk jobs.StartInput{
                .program = program,
                .args = args_storage.items,
                .cwd = cwd,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseShellStartInput(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    args_storage: *std.ArrayList([]const u8),
    writer: *std.Io.Writer,
) !?shells.StartInput {
    const value = arguments orelse return shells.StartInput{};
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "shell", "args", "cwd", "cols", "rows" })) {
                try writeInvalidRequest(writer, "Invalid shell_start arguments");
                break :blk null;
            }
            const shell = if (object.get("shell")) |shell_value| switch (shell_value) {
                .string => |text| blk_shell: {
                    if (text.len == 0) {
                        try writeInvalidRequest(writer, "shell must not be empty");
                        break :blk null;
                    }
                    break :blk_shell text;
                },
                else => {
                    try writeInvalidRequest(writer, "shell must be a string");
                    break :blk null;
                },
            } else null;
            if (object.get("args")) |args_value| switch (args_value) {
                .array => |array| {
                    for (array.items) |arg_value| switch (arg_value) {
                        .string => |text| try args_storage.append(allocator, text),
                        else => {
                            try writeInvalidRequest(writer, "args must be an array of strings");
                            break :blk null;
                        },
                    };
                },
                else => {
                    try writeInvalidRequest(writer, "args must be an array of strings");
                    break :blk null;
                },
            };
            const cwd = if (object.get("cwd")) |cwd_value| switch (cwd_value) {
                .string => |text| text,
                else => {
                    try writeInvalidRequest(writer, "cwd must be a string");
                    break :blk null;
                },
            } else null;
            const cols = try parseTerminalDimension(object, "cols", 120, writer) orelse break :blk null;
            const rows = try parseTerminalDimension(object, "rows", 30, writer) orelse break :blk null;
            break :blk shells.StartInput{
                .shell = shell,
                .args = args_storage.items,
                .cwd = cwd,
                .cols = cols,
                .rows = rows,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseTerminalDimension(
    object: std.json.ObjectMap,
    name: []const u8,
    default_value: u16,
    writer: *std.Io.Writer,
) !?u16 {
    const value = object.get(name) orelse return default_value;
    return switch (value) {
        .integer => |number| blk: {
            if (number <= 0 or number > std.math.maxInt(u16)) {
                try writeInvalidRequest(writer, "terminal dimensions must be integers from 1 to 65535");
                break :blk null;
            }
            break :blk @intCast(number);
        },
        else => blk: {
            try writeInvalidRequest(writer, "terminal dimensions must be integers");
            break :blk null;
        },
    };
}

fn parseShellResizeInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?ShellResizeArguments {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "shell_resize requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "shellId", "cols", "rows" })) {
                try writeInvalidRequest(writer, "Invalid shell_resize arguments");
                break :blk null;
            }
            const shell_id = getPositiveId(object, "shellId") orelse {
                try writeInvalidRequest(writer, "shellId must be a positive integer");
                break :blk null;
            };
            const cols = try parseTerminalDimension(object, "cols", 0, writer) orelse break :blk null;
            const rows = try parseTerminalDimension(object, "rows", 0, writer) orelse break :blk null;
            if (object.get("cols") == null or object.get("rows") == null) {
                try writeInvalidRequest(writer, "shell_resize requires cols and rows");
                break :blk null;
            }
            break :blk .{ .shellId = shell_id, .cols = cols, .rows = rows };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseShellWriteInput(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?ShellWriteArguments {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "shell_write requires arguments");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ "shellId", "input", "enter" })) {
                try writeInvalidRequest(writer, "Invalid shell_write arguments");
                break :blk null;
            }
            const shell_id = getPositiveId(object, "shellId") orelse {
                try writeInvalidRequest(writer, "shellId must be a positive integer");
                break :blk null;
            };
            const input = getString(object, "input") orelse {
                try writeInvalidRequest(writer, "input must be a string");
                break :blk null;
            };
            const enter = if (object.get("enter")) |enter_value| switch (enter_value) {
                .bool => |flag| flag,
                else => {
                    try writeInvalidRequest(writer, "enter must be a boolean");
                    break :blk null;
                },
            } else true;
            break :blk ShellWriteArguments{
                .shellId = shell_id,
                .input = input,
                .enter = enter,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseStreamReadArguments(
    arguments: ?std.json.Value,
    comptime id_field: []const u8,
    writer: *std.Io.Writer,
) !?StreamReadArguments {
    const value = arguments orelse {
        try writeInvalidRequest(writer, id_field ++ " is required");
        return null;
    };

    return switch (value) {
        .object => |object| blk: {
            if (!hasOnlyFields(object, &.{ id_field, "stdoutAfter", "stderrAfter" })) {
                try writeInvalidRequest(writer, "Invalid stream read arguments");
                break :blk null;
            }

            const id = getPositiveId(object, id_field) orelse {
                try writeInvalidRequest(writer, id_field ++ " must be greater than zero");
                break :blk null;
            };

            const stdout_after: ?u64 = if (object.get("stdoutAfter")) |cursor_value|
                try parseCursorValue(cursor_value, writer) orelse break :blk null
            else
                null;
            const stderr_after: ?u64 = if (object.get("stderrAfter")) |cursor_value|
                try parseCursorValue(cursor_value, writer) orelse break :blk null
            else
                null;

            break :blk StreamReadArguments{
                .id = id,
                .stdout_after = stdout_after,
                .stderr_after = stderr_after,
            };
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn parseCursorValue(
    value: std.json.Value,
    writer: *std.Io.Writer,
) !?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0)
            @as(u64, @intCast(number))
        else blk: {
            try writeInvalidRequest(writer, "output cursor must be a non-negative integer");
            break :blk null;
        },
        else => blk: {
            try writeInvalidRequest(writer, "output cursor must be a non-negative integer");
            break :blk null;
        },
    };
}

fn parseIdArgument(
    arguments: ?std.json.Value,
    comptime field_name: []const u8,
    writer: *std.Io.Writer,
) !?u64 {
    const value = arguments orelse {
        try writeInvalidRequest(writer, field_name ++ " is required");
        return null;
    };
    return switch (value) {
        .object => |object| blk: {
            if (object.count() != 1) {
                try writeInvalidRequest(writer, "Invalid id arguments");
                break :blk null;
            }
            const id = getPositiveId(object, field_name) orelse {
                try writeInvalidRequest(writer, field_name ++ " must be greater than zero");
                break :blk null;
            };
            break :blk id;
        },
        else => blk: {
            try writeInvalidRequest(writer, "arguments must be an object");
            break :blk null;
        },
    };
}

fn hasOnlyFields(object: anytype, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn getString(object: anytype, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn getPositiveId(object: anytype, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number > 0) @as(u64, @intCast(number)) else null,
        else => null,
    };
}

fn requireNoArguments(
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !bool {
    const value = arguments orelse return true;
    switch (value) {
        .object => |object| {
            if (object.count() == 0) return true;
        },
        else => {},
    }
    try writeInvalidRequest(writer, "operation accepts no arguments");
    return false;
}

fn writeSuccess(
    writer: *std.Io.Writer,
    result: anytype,
    is_error: bool,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = true,
        .result = result,
        .isError = is_error,
    }, .{ .emit_null_optional_fields = false })});
}

fn writeFailure(
    writer: *std.Io.Writer,
    code: []const u8,
    message: []const u8,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .isError = true,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{})});
}

fn writeFailureWithDetails(
    writer: *std.Io.Writer,
    code: []const u8,
    message: []const u8,
    details: anytype,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .isError = true,
        .@"error" = .{
            .code = code,
            .message = message,
            .details = details,
        },
    }, .{})});
}

fn writeInvalidRequest(
    writer: *std.Io.Writer,
    message: []const u8,
) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .invalidRequest = true,
        .isError = true,
        .@"error" = .{
            .code = "InvalidRequest",
            .message = message,
        },
    }, .{})});
}
