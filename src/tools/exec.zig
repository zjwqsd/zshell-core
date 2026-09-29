const std = @import("std");
const builtin = @import("builtin");
const secrets = @import("../runtime/secrets.zig");
const jobs = @import("jobs.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const default_timeout_ms: u64 = 60_000;
pub const max_timeout_ms: u64 = 60 * 60 * 1000;
pub const output_limit_bytes: usize = 4 * 1024 * 1024;
pub const wait_poll_interval_ms: u64 = 20;

pub const shell_name = if (builtin.os.tag == .linux and builtin.abi == .android)
    "/system/bin/sh"
else switch (builtin.os.tag) {
    .windows => "pwsh.exe",
    .linux => "/bin/bash",
    .macos => "/bin/zsh",
    else => "/bin/sh",
};

pub const Input = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    timeoutMs: u64 = default_timeout_ms,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: ?u8,
    termination: []const u8,
    timed_out: bool,
    termination_source: Source,
    job_id: ?jobs.JobId = null,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn succeeded(self: Result) bool {
        // Promotion is a successful exec handoff, not a command failure.
        if (self.job_id != null) return true;
        if (self.timed_out) return false;
        return (self.exit_code orelse return false) == 0;
    }
};

pub const ValidationError = error{
    EmptyCommand,
    InvalidTimeout,
};

pub fn validate(input: Input) ValidationError!void {
    if (input.command.len == 0) return error.EmptyCommand;
    if (input.timeoutMs == 0 or input.timeoutMs > max_timeout_ms) {
        return error.InvalidTimeout;
    }
}

pub const Cancellation = struct {
    context: *anyopaque,
    requested: *const fn (*anyopaque, std.Io) ?Source,

    pub fn source(self: Cancellation, io: std.Io) ?Source {
        return self.requested(self.context, io);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
) !Result {
    return runControlled(allocator, io, input, null);
}

pub fn runControlled(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
    cancellation: ?Cancellation,
) !Result {
    try validate(input);
    return runShell(allocator, io, input, cancellation);
}

fn runShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
    cancellation: ?Cancellation,
) !Result {
    var command_writer: std.Io.Writer.Allocating = .init(allocator);
    defer command_writer.deinit();

    return switch (builtin.os.tag) {
        .windows => blk: {
            try command_writer.writer.writeAll(secrets.powershell_clear);
            try command_writer.writer.writeAll(
                "$__zshell_utf8 = " ++
                    "[System.Text.UTF8Encoding]::new($false); " ++
                    "[Console]::OutputEncoding = $__zshell_utf8; " ++
                    "$OutputEncoding = $__zshell_utf8; ",
            );
            try command_writer.writer.writeAll(input.command);
            const args = &.{
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                command_writer.written(),
            };
            break :blk runAsTransientJob(
                allocator,
                io,
                input,
                cancellation,
                "pwsh.exe",
                args,
                "powershell.exe",
            );
        },
        .linux, .macos => blk: {
            try command_writer.writer.writeAll(secrets.posix_clear);
            try command_writer.writer.writeAll(input.command);
            break :blk runAsTransientJob(
                allocator,
                io,
                input,
                cancellation,
                shell_name,
                &.{ "-c", command_writer.written() },
                null,
            );
        },
        else => blk: {
            try command_writer.writer.writeAll(secrets.posix_clear);
            try command_writer.writer.writeAll(input.command);
            break :blk runAsTransientJob(
                allocator,
                io,
                input,
                cancellation,
                "/bin/sh",
                &.{ "-c", command_writer.written() },
                null,
            );
        },
    };
}

fn runAsTransientJob(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
    cancellation: ?Cancellation,
    program: []const u8,
    args: []const []const u8,
    fallback_program: ?[]const u8,
) !Result {
    const started = jobs.startTransient(.{
        .program = program,
        .args = args,
        .cwd = input.cwd,
    }, output_limit_bytes) catch |err| switch (err) {
        error.FileNotFound => if (fallback_program) |fallback|
            try jobs.startTransient(.{
                .program = fallback,
                .args = args,
                .cwd = input.cwd,
            }, output_limit_bytes)
        else
            return err,
        else => return err,
    };
    const job_id = started.job_id;

    // Unless promotion succeeds, this request owns the hidden job and must
    // leave no registry entry or process behind on any error path.
    var released = false;
    defer if (!released) cleanupTransient(job_id);

    const began = std.Io.Clock.Timestamp.now(io, .awake);
    const timeout_ns = input.timeoutMs * std.time.ns_per_ms;
    const poll_ns = wait_poll_interval_ms * std.time.ns_per_ms;

    while (true) {
        const status = try jobs.status(job_id);
        try checkOutputLimits(status);

        if (status.status != .running) {
            const result = try collectFinished(allocator, job_id, status);
            try jobs.discardFinished(job_id);
            released = true;
            return result;
        }

        if (cancellation) |probe| {
            if (probe.source(io)) |source| {
                const stopped = try jobs.stopBy(job_id, source);
                const result = try collectFinished(allocator, job_id, stopped);
                try jobs.discardFinished(job_id);
                released = true;
                return result;
            }
        }

        const elapsed_ns = elapsedNanoseconds(began, io);
        if (elapsed_ns >= timeout_ns) {
            try jobs.promote(job_id);
            released = true;

            const logs = try jobs.logs(allocator, job_id, null, null);
            return .{
                .stdout = logs.stdout,
                .stderr = logs.stderr,
                .exit_code = null,
                .termination = "promoted_to_job",
                .timed_out = true,
                .termination_source = .system,
                .job_id = job_id,
            };
        }

        const remaining_ns = timeout_ns - elapsed_ns;
        try io.sleep(.fromNanoseconds(@intCast(@min(remaining_ns, poll_ns))), .awake);
    }
}

fn collectFinished(
    allocator: std.mem.Allocator,
    job_id: jobs.JobId,
    status: jobs.StatusResult,
) !Result {
    const logs = try jobs.logs(allocator, job_id, null, null);
    const source = status.termination_source orelse .system;
    const termination = switch (status.status) {
        .exited => status.termination orelse "exited",
        .stopped => "killed",
        .failed => status.worker_error orelse status.termination orelse "worker_error",
        .running => unreachable,
    };
    return .{
        .stdout = logs.stdout,
        .stderr = logs.stderr,
        .exit_code = status.exit_code,
        .termination = termination,
        .timed_out = false,
        .termination_source = source,
    };
}

fn cleanupTransient(job_id: jobs.JobId) void {
    const status = jobs.status(job_id) catch return;
    if (status.status == .running) {
        _ = jobs.stopBy(job_id, .system) catch return;
    }
    jobs.discardFinished(job_id) catch {};
}

fn checkOutputLimits(status: jobs.StatusResult) !void {
    if (status.stdout_bytes > output_limit_bytes) return error.StdoutStreamTooLong;
    if (status.stderr_bytes > output_limit_bytes) return error.StderrStreamTooLong;
}

fn elapsedNanoseconds(started: std.Io.Clock.Timestamp, io: std.Io) u64 {
    const raw = started.untilNow(io).raw.nanoseconds;
    if (raw <= 0) return 0;
    return @intCast(raw);
}

// Tests

fn initTestJobs(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(allocator);
    errdefer environ.deinit();
    try jobs.init(allocator, std.testing.io, &environ);
    return environ;
}

test "validate exec input" {
    try std.testing.expectError(
        error.EmptyCommand,
        validate(
            .{
                .command = "",
            },
        ),
    );

    try std.testing.expectError(
        error.InvalidTimeout,
        validate(
            .{
                .command = "echo test",

                .timeoutMs = 0,
            },
        ),
    );

    try std.testing.expectError(
        error.InvalidTimeout,
        validate(
            .{
                .command = "echo test",

                .timeoutMs = max_timeout_ms + 1,
            },
        ),
    );
}

test "exec captures stdout" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const command =
        switch (builtin.os.tag) {
            .windows => "Write-Output 'zshell-exec-ok'",

            else => "printf 'zshell-exec-ok'",
        };

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = command,
            },
        );
    defer result.deinit(
        allocator,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            result.stdout,
            "zshell-exec-ok",
        ) != null,
    );

    try std.testing.expect(
        result.succeeded(),
    );

    try std.testing.expectEqual(
        @as(?u8, 0),
        result.exit_code,
    );

    try std.testing.expectEqualStrings(
        "exited",
        result.termination,
    );

    try std.testing.expect(
        !result.timed_out,
    );
}

test "exec captures stdout and stderr separately" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const command =
        switch (builtin.os.tag) {
            .windows => "[Console]::Out.WriteLine('stdout-marker'); " ++
                "[Console]::Error.WriteLine('stderr-marker')",

            else => "printf 'stdout-marker'; " ++
                "printf 'stderr-marker' >&2",
        };

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = command,
            },
        );
    defer result.deinit(
        allocator,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            result.stdout,
            "stdout-marker",
        ) != null,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            result.stderr,
            "stderr-marker",
        ) != null,
    );
}

test "nonzero exit code is preserved" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = "exit 7",
            },
        );
    defer result.deinit(
        allocator,
    );

    try std.testing.expect(
        !result.succeeded(),
    );

    try std.testing.expectEqual(
        @as(?u8, 7),
        result.exit_code,
    );

    try std.testing.expectEqualStrings(
        "exited",
        result.termination,
    );

    try std.testing.expect(
        !result.timed_out,
    );
}

test "unicode output is UTF-8" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const command =
        switch (builtin.os.tag) {
            .windows => "Write-Output '娑擃厽鏋冨ù瀣槸-娴ｇ姴銈?zshell'",

            else => "printf '娑擃厽鏋冨ù瀣槸-娴ｇ姴銈?zshell'",
        };

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = command,
            },
        );
    defer result.deinit(
        allocator,
    );

    try std.testing.expect(
        result.succeeded(),
    );

    try std.testing.expect(
        std.unicode.utf8ValidateSlice(
            result.stdout,
        ),
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            result.stdout,
            "娑擃厽鏋冨ù瀣槸-娴ｇ姴銈?zshell",
        ) != null,
    );
}

test "timeout promotes running command to visible job" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const began = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = try run(allocator, std.testing.io, .{
        .command = "printf 'before'; sleep 5",
        .timeoutMs = 100,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.succeeded());
    try std.testing.expect(result.timed_out);
    try std.testing.expectEqualStrings("promoted_to_job", result.termination);
    try std.testing.expect(result.job_id != null);
    try std.testing.expect(elapsedNanoseconds(began, std.testing.io) < 4 * std.time.ns_per_s);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "before") != null);

    const job_id = result.job_id.?;
    const list = try jobs.list(allocator);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(job_id, list.items[0].job_id);

    const stopped = try jobs.stop(job_id);
    try std.testing.expectEqual(jobs.Status.stopped, stopped.status);
}

test "promoted exec continues and retains later output" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const result = try run(allocator, std.testing.io, .{
        .command = "printf 'before-'; sleep 0.2; printf 'after'",
        .timeoutMs = 50,
    });
    defer result.deinit(allocator);
    const job_id = result.job_id.?;

    var finished = false;
    for (0..100) |_| {
        const current = try jobs.status(job_id);
        if (current.status != .running) {
            finished = true;
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(finished);

    const logs = try jobs.logs(allocator, job_id, null, null);
    defer logs.deinit(allocator);
    try std.testing.expectEqualStrings("before-after", logs.stdout);
    try std.testing.expectEqualStrings("", logs.stderr);
}

test "short exec leaves no visible or hidden job" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();

    const result = try run(allocator, std.testing.io, .{
        .command = "printf done",
        .timeoutMs = 1000,
    });
    defer result.deinit(allocator);
    try std.testing.expect(result.job_id == null);
    try std.testing.expectEqualStrings("done", result.stdout);

    const list = try jobs.list(allocator);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "macos exec uses zsh" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const result = try run(
        allocator,
        std.testing.io,
        .{ .command = "printf '%s\\n' {alpha,beta}" },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("alpha\nbeta\n", result.stdout);
    try std.testing.expect(result.succeeded());
}

test "linux exec supports bash syntax" {
    const allocator = std.testing.allocator;
    var environ = try initTestJobs(allocator);
    defer environ.deinit();
    defer jobs.deinit();
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const result = try run(
        allocator,
        std.testing.io,
        .{ .command = "printf '%s\\n' {alpha,beta}" },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("alpha\nbeta\n", result.stdout);
    try std.testing.expect(result.succeeded());
}
