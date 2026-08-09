const std = @import("std");
const builtin = @import("builtin");
const secrets = @import("../runtime/secrets.zig");

const TailBuffer = @import("tail_buffer.zig").TailBuffer;
const events = @import("../control/events.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const log_buffer_bytes: usize = 1024 * 1024;
pub const poll_interval_ms: i64 = 100;

pub const JobId = u64;

pub const Status = enum {
    running,
    exited,
    stopped,
    failed,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const StartInput = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
};

pub const StartResult = struct {
    job_id: JobId,
    status: Status,
};

pub const StatusResult = struct {
    job_id: JobId,
    command: []const u8,
    cwd: ?[]const u8,
    status: Status,
    exit_code: ?u8,
    termination: ?[]const u8,
    worker_error: ?[]const u8,
    termination_source: ?Source,
    stdout_truncated: bool,
    stderr_truncated: bool,
    stdout_bytes: u64,
    stderr_bytes: u64,
};

pub const LogsResult = struct {
    job_id: JobId,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    stdout_bytes: u64,
    stderr_bytes: u64,

    pub fn deinit(self: LogsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const ListItem = struct {
    job_id: JobId,
    command: []const u8,
    cwd: ?[]const u8,
    status: Status,
    exit_code: ?u8,
    termination_source: ?Source,
};

pub const ListResult = struct {
    items: []ListItem,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub const Error = error{JobNotFound};

const Job = struct {
    id: JobId,
    io: std.Io,
    command: []u8,
    cwd: ?[]u8,

    mutex: std.Io.Mutex = .init,
    status: Status = .running,
    exit_code: ?u8 = null,
    termination: ?[]const u8 = null,
    worker_error: ?[]const u8 = null,
    termination_source: ?Source = null,
    stop_requested: ?Source = null,

    stdout: TailBuffer,
    stderr: TailBuffer,

    thread: ?std.Thread = null,
    thread_claimed: bool = false,

    fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    jobs: std.AutoHashMap(JobId, *Job),
    next_id: JobId = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .jobs = std.AutoHashMap(JobId, *Job).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        // Shutdown is cooperative: request stop first, then join every worker,
        // then release the registry. Locks are never held across join().
        var iterator = self.jobs.iterator();
        while (iterator.next()) |entry| {
            const job = entry.value_ptr.*;
            job.mutex.lockUncancelable(job.io);
            if (job.status == .running and job.stop_requested == null) job.stop_requested = .system;
            job.mutex.unlock(job.io);
        }

        iterator = self.jobs.iterator();
        while (iterator.next()) |entry| {
            if (claimThread(entry.value_ptr.*)) |thread| thread.join();
        }

        iterator = self.jobs.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }

        self.jobs.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Manager, input: StartInput) !StartResult {
        if (input.command.len == 0) return error.EmptyCommand;

        // Jobs outlive the request that created them, so request-owned strings
        // are copied into the manager allocator.
        const command = try self.allocator.dupe(u8, input.command);
        errdefer self.allocator.free(command);

        const cwd = if (input.cwd) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (cwd) |value| self.allocator.free(value);

        var stdout = try TailBuffer.init(self.allocator, log_buffer_bytes);
        errdefer stdout.deinit(self.allocator);

        var stderr = try TailBuffer.init(self.allocator, log_buffer_bytes);
        errdefer stderr.deinit(self.allocator);

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);

        self.mutex.lockUncancelable(self.io);
        const job_id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock(self.io);

        job.* = .{
            .id = job_id,
            .io = self.io,
            .command = command,
            .cwd = cwd,
            .stdout = stdout,
            .stderr = stderr,
        };

        // A successful start means the OS process has already been created.
        var child = try spawnShell(self.allocator, self.io, input);
        var child_owned = true;
        errdefer if (child_owned) child.kill(self.io);

        self.mutex.lockUncancelable(self.io);
        self.jobs.put(job_id, job) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);

        errdefer {
            self.mutex.lockUncancelable(self.io);
            _ = self.jobs.remove(job_id);
            self.mutex.unlock(self.io);
            job.deinit(self.allocator);
        }

        const thread = try std.Thread.spawn(
            .{},
            workerMain,
            .{WorkerContext{
                .io = self.io,
                .allocator = self.allocator,
                .job = job,
                .child = child,
            }},
        );
        child_owned = false;

        job.mutex.lockUncancelable(job.io);
        job.thread = thread;
        job.mutex.unlock(job.io);

        events.record(self.io, .agent, "job.started", .job, job_id, input.command);
        return .{ .job_id = job_id, .status = .running };
    }

    pub fn status(self: *Manager, job_id: JobId) Error!StatusResult {
        const job = try self.getJob(job_id);
        reapFinishedThread(job);

        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);
        return snapshotStatus(job);
    }

    pub fn logs(
        self: *Manager,
        allocator: std.mem.Allocator,
        job_id: JobId,
    ) !LogsResult {
        const job = try self.getJob(job_id);

        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);

        // Copy under the lock so the HTTP response never aliases a buffer that
        // the worker can mutate after the lock is released.
        const stdout_copy = try allocator.dupe(u8, job.stdout.slice());
        errdefer allocator.free(stdout_copy);
        const stderr_copy = try allocator.dupe(u8, job.stderr.slice());

        return .{
            .job_id = job.id,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .stdout_truncated = job.stdout.truncated(),
            .stderr_truncated = job.stderr.truncated(),
            .stdout_bytes = job.stdout.total_bytes,
            .stderr_bytes = job.stderr.total_bytes,
        };
    }

    pub fn stop(self: *Manager, job_id: JobId, source: Source) Error!StatusResult {
        const job = try self.getJob(job_id);

        // The worker owns Child. Request threads only set the stop request,
        // then join the worker so stop() returns after the process is gone.
        job.mutex.lockUncancelable(job.io);
        if (job.status == .running and job.stop_requested == null) {
            job.stop_requested = source;
        }
        job.mutex.unlock(job.io);

        if (claimThread(job)) |thread| thread.join();

        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);
        return snapshotStatus(job);
    }

    pub fn list(self: *Manager, allocator: std.mem.Allocator) !ListResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const items = try allocator.alloc(ListItem, self.jobs.count());
        errdefer allocator.free(items);

        var index: usize = 0;
        var iterator = self.jobs.iterator();
        while (iterator.next()) |entry| {
            const job = entry.value_ptr.*;
            job.mutex.lockUncancelable(job.io);
            items[index] = .{
                .job_id = job.id,
                .command = job.command,
                .cwd = job.cwd,
                .status = job.status,
                .exit_code = job.exit_code,
                .termination_source = job.termination_source,
            };
            job.mutex.unlock(job.io);
            index += 1;
        }

        return .{ .items = items };
    }

    fn getJob(self: *Manager, job_id: JobId) Error!*Job {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.jobs.get(job_id) orelse error.JobNotFound;
    }
};

const WorkerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    job: *Job,
    child: std.process.Child,
};

fn workerMain(context: WorkerContext) void {
    runWorker(context) catch |err| {
        // The request that started this job has already returned, so worker
        // failures are stored explicitly instead of being discarded.
        const job = context.job;
        job.mutex.lockUncancelable(job.io);
        job.status = .failed;
        job.worker_error = @errorName(err);
        job.termination = "worker_error";
        job.termination_source = .system;
        job.mutex.unlock(job.io);
        events.record(job.io, .system, "job.failed", .job, job.id, @errorName(err));
    };
}

fn runWorker(context: WorkerContext) !void {
    const io = context.io;
    const job = context.job;
    var child = context.child;
    var child_active = true;

    defer if (child_active) child.kill(io);

    // Drain both pipes together so neither stream can fill and block the child.
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        context.allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = .fromMilliseconds(poll_interval_ms),
            .clock = .awake,
        },
    };

    while (true) {
        drainBuffered(job, stdout_reader, stderr_reader);

        if (stopSource(job)) |source| {
            child.kill(io);
            child_active = false;
            drainBuffered(job, stdout_reader, stderr_reader);
            setStopped(job, source);
            events.record(io, source, "job.stopped", .job, job.id, "stopped");
            return;
        }

        multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
            error.EndOfStream => {
                drainBuffered(job, stdout_reader, stderr_reader);
                break;
            },
            // This timeout is only the stop polling interval. Jobs themselves
            // have no automatic deadline.
            error.Timeout => continue,
            else => return err,
        };
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    child_active = false;
    setTerminated(job, term);
    events.record(io, .process, "job.exited", .job, job.id, terminationFromTerm(term));
}

fn drainBuffered(
    job: *Job,
    stdout_reader: *std.Io.Reader,
    stderr_reader: *std.Io.Reader,
) void {
    const stdout = stdout_reader.buffered();
    const stderr = stderr_reader.buffered();
    if (stdout.len == 0 and stderr.len == 0) return;

    job.mutex.lockUncancelable(job.io);
    job.stdout.append(stdout);
    job.stderr.append(stderr);
    job.mutex.unlock(job.io);

    // The data is now in the bounded tail buffers; release MultiReader's copy.
    stdout_reader.tossBuffered();
    stderr_reader.tossBuffered();
}

fn stopSource(job: *Job) ?Source {
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);
    return job.stop_requested;
}

fn setStopped(job: *Job, source: Source) void {
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);
    job.status = .stopped;
    job.exit_code = null;
    job.termination = "stopped";
    job.termination_source = source;
}

fn setTerminated(job: *Job, term: std.process.Child.Term) void {
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);
    job.status = .exited;
    job.exit_code = exitCodeFromTerm(term);
    job.termination = terminationFromTerm(term);
    job.termination_source = .process;
}

fn snapshotStatus(job: *const Job) StatusResult {
    return .{
        .job_id = job.id,
        .command = job.command,
        .cwd = job.cwd,
        .status = job.status,
        .exit_code = job.exit_code,
        .termination = job.termination,
        .worker_error = job.worker_error,
        .termination_source = job.termination_source,
        .stdout_truncated = job.stdout.truncated(),
        .stderr_truncated = job.stderr.truncated(),
        .stdout_bytes = job.stdout.total_bytes,
        .stderr_bytes = job.stderr.total_bytes,
    };
}

fn claimThread(job: *Job) ?std.Thread {
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);

    if (job.thread_claimed) return null;
    const thread = job.thread orelse return null;
    job.thread_claimed = true;
    job.thread = null;
    return thread;
}

fn reapFinishedThread(job: *Job) void {
    job.mutex.lockUncancelable(job.io);
    const finished = job.status != .running;
    job.mutex.unlock(job.io);

    if (finished) {
        if (claimThread(job)) |thread| thread.join();
    }
}

fn spawnShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: StartInput,
) !std.process.Child {
    return switch (builtin.os.tag) {
        .windows => blk: {
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

            break :blk try spawnProcess(
                io,
                &.{
                    "powershell.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    command_writer.written(),
                },
                input.cwd,
            );
        },
        else => blk: {
            var command_writer: std.Io.Writer.Allocating = .init(allocator);
            defer command_writer.deinit();
            try command_writer.writer.writeAll(secrets.posix_clear);
            try command_writer.writer.writeAll(input.command);

            break :blk try spawnProcess(
                io,
                &.{ "/bin/sh", "-c", command_writer.written() },
                input.cwd,
            );
        },
    };
}

fn spawnProcess(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !std.process.Child {
    if (cwd) |value| {
        return try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = value },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
    }

    return try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
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
