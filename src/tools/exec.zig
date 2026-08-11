const std = @import("std");
const builtin = @import("builtin");
const secrets = @import("../runtime/secrets.zig");
const process_tree = @import("../runtime/process_tree.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const default_timeout_ms: u64 = 60_000;
pub const max_timeout_ms: u64 = 60 * 60 * 1000;
pub const output_limit_bytes: usize = 4 * 1024 * 1024;
pub const reader_drain_timeout_ms: u64 = 2_000;
pub const cancel_poll_interval_ms: u64 = 100;

pub const shell_name = switch (builtin.os.tag) {
    .windows => "powershell.exe",
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

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn succeeded(self: Result) bool {
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
    return switch (builtin.os.tag) {
        .windows => blk: {
            // PowerShell 5.1 does not reliably emit UTF-8 when stdout/stderr
            // are pipes, while the device protocol boundary requires UTF-8 text.
            var command_writer: std.Io.Writer.Allocating = .init(allocator);
            defer command_writer.deinit();

            try command_writer.writer.writeAll(secrets.powershell_clear);
            try command_writer.writer.writeAll(
                "$__zshell_utf8 = " ++
                    "[System.Text.UTF8Encoding]::new($false); " ++
                    "[Console]::OutputEncoding = $__zshell_utf8; " ++
                    "$OutputEncoding = $__zshell_utf8; ",
            );
            try command_writer.writer.writeAll(input.command);

            break :blk try runProcess(
                allocator,
                io,
                &.{
                    "powershell.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    command_writer.written(),
                },
                input,
                cancellation,
            );
        },
        .linux => blk: {
            var command_writer: std.Io.Writer.Allocating = .init(allocator);
            defer command_writer.deinit();
            try command_writer.writer.writeAll(secrets.posix_clear);
            try command_writer.writer.writeAll(input.command);

            break :blk try runProcess(
                allocator,
                io,
                &.{ "setsid", "/bin/sh", "-c", command_writer.written() },
                input,
                cancellation,
            );
        },
        else => blk: {
            var command_writer: std.Io.Writer.Allocating = .init(allocator);
            defer command_writer.deinit();
            try command_writer.writer.writeAll(secrets.posix_clear);
            try command_writer.writer.writeAll(input.command);

            break :blk try runProcess(
                allocator,
                io,
                &.{ "/bin/sh", "-c", command_writer.written() },
                input,
                cancellation,
            );
        },
    };
}

fn runProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: Input,
    cancellation: ?Cancellation,
) !Result {
    var child = if (input.cwd) |cwd|
        try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        })
    else
        try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });

    // After spawn, every error path must terminate the child.
    var child_finished = false;
    defer if (!child_finished) process_tree.terminate(&child, io);

    // Read stdout and stderr together so neither pipe can fill and deadlock the
    // child while the parent waits on the other stream.
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    // All fills share one command-wide deadline. Reusing the full timeout for
    // every fill would let a continuously-writing child extend its lifetime.
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const timeout_ns = input.timeoutMs * std.time.ns_per_ms;
    const poll_ns = cancel_poll_interval_ms * std.time.ns_per_ms;
    var did_timeout = false;
    var cancelled_by: ?Source = null;

    while (true) {
        try checkOutputLimits(stdout_reader, stderr_reader);

        if (cancellation) |probe| {
            if (probe.source(io)) |source| {
                cancelled_by = source;
                break;
            }
        }

        const elapsed_ns = elapsedNanoseconds(started, io);
        if (elapsed_ns >= timeout_ns) {
            did_timeout = true;
            break;
        }

        const remaining_ns = timeout_ns - elapsed_ns;
        const fill_ns = @min(remaining_ns, poll_ns);
        multi_reader.fill(1, relativeTimeout(fill_ns)) catch |err| switch (err) {
            error.EndOfStream => break,
            // Short fill timeouts are cancellation polling points. The command
            // deadline is checked at the top of the next iteration.
            error.Timeout => continue,
            else => return err,
        };
    }

    try checkOutputLimits(stdout_reader, stderr_reader);

    if (did_timeout or cancelled_by != null) {
        process_tree.terminate(&child, io);
        child_finished = true;

        try drainAfterTermination(
            &multi_reader,
            stdout_reader,
            stderr_reader,
            io,
        );

        const stdout = try multi_reader.toOwnedSlice(0);
        errdefer allocator.free(stdout);
        const stderr = try multi_reader.toOwnedSlice(1);
        errdefer allocator.free(stderr);

        if (cancelled_by) |source| {
            return .{
                .stdout = stdout,
                .stderr = stderr,
                .exit_code = null,
                .termination = "killed",
                .timed_out = false,
                .termination_source = source,
            };
        }

        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = null,
            .termination = "timeout",
            .timed_out = true,
            .termination_source = .system,
        };
    }

    try multi_reader.checkAnyError();

    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);

    const term = try child.wait(io);
    child_finished = true;

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exitCodeFromTerm(term),
        .termination = terminationFromTerm(term),
        .timed_out = false,
        .termination_source = .process,
    };
}

fn drainAfterTermination(
    multi_reader: *std.Io.File.MultiReader,
    stdout_reader: *std.Io.Reader,
    stderr_reader: *std.Io.Reader,
    io: std.Io,
) !void {
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const drain_timeout_ns = reader_drain_timeout_ms * std.time.ns_per_ms;

    while (true) {
        try checkOutputLimits(stdout_reader, stderr_reader);

        const elapsed_ns = elapsedNanoseconds(started, io);
        if (elapsed_ns >= drain_timeout_ns) return;

        multi_reader.fill(
            1,
            relativeTimeout(drain_timeout_ns - elapsed_ns),
        ) catch |err| switch (err) {
            error.EndOfStream, error.Timeout => return,
            else => return err,
        };
    }
}

fn relativeTimeout(nanoseconds: u64) std.Io.Timeout {
    const signed: i64 = @intCast(nanoseconds);
    return .{
        .duration = .{
            .raw = .fromNanoseconds(signed),
            .clock = .awake,
        },
    };
}

fn elapsedNanoseconds(started: std.Io.Clock.Timestamp, io: std.Io) u64 {
    const raw = started.untilNow(io).raw.nanoseconds;
    if (raw <= 0) return 0;
    return @intCast(raw);
}

fn checkOutputLimits(
    stdout_reader: *std.Io.Reader,
    stderr_reader: *std.Io.Reader,
) !void {
    if (stdout_reader.buffered().len > output_limit_bytes) {
        return error.StdoutStreamTooLong;
    }
    if (stderr_reader.buffered().len > output_limit_bytes) {
        return error.StderrStreamTooLong;
    }
}

fn exitCodeFromTerm(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => null,
    };
}

fn terminationFromTerm(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => "exited",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

// Tests

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
    const allocator =
        std.testing.allocator;

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
    const allocator =
        std.testing.allocator;

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
    const allocator =
        std.testing.allocator;

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
    const allocator =
        std.testing.allocator;

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

test "timeout terminates command" {
    const allocator =
        std.testing.allocator;

    const command =
        switch (builtin.os.tag) {
            .windows => "Start-Sleep -Seconds 5",

            else => "sleep 5",
        };

    const started =
        std.Io.Clock.Timestamp.now(
            std.testing.io,
            .awake,
        );

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = command,

                .timeoutMs = 300,
            },
        );
    defer result.deinit(
        allocator,
    );

    const elapsed_ns =
        elapsedNanoseconds(
            started,
            std.testing.io,
        );

    try std.testing.expect(
        result.timed_out,
    );

    try std.testing.expect(
        !result.succeeded(),
    );

    try std.testing.expectEqual(
        @as(?u8, null),
        result.exit_code,
    );

    try std.testing.expectEqualStrings(
        "timeout",
        result.termination,
    );

    //
    // Start-Sleep 5 缁夋帪绱濇担鍡楃安鐠囥儲妲戦弰鐐－娴?5 缁夋帞绮ㄩ弶鐔粹偓?    //
    try std.testing.expect(
        elapsed_ns <
            4 * std.time.ns_per_s,
    );
}

test "timeout preserves earlier stdout" {
    const allocator =
        std.testing.allocator;

    const command =
        switch (builtin.os.tag) {
            .windows => "Write-Output 'before-timeout'; " ++
                "Start-Sleep -Seconds 5",

            else => "printf 'before-timeout'; " ++
                "sleep 5",
        };

    const result =
        try run(
            allocator,
            std.testing.io,
            .{
                .command = command,

                .timeoutMs = 500,
            },
        );
    defer result.deinit(
        allocator,
    );

    try std.testing.expect(
        result.timed_out,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            result.stdout,
            "before-timeout",
        ) != null,
    );
}
