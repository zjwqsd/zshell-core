const std = @import("std");
const builtin = @import("builtin");
const secrets = @import("../runtime/secrets.zig");
const process_tree = @import("../runtime/process_tree.zig");

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
    program: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
};

pub const StartResult = struct {
    job_id: JobId,
    status: Status,
};

pub const StatusResult = struct {
    job_id: JobId,
    program: []const u8,
    args: []const []const u8,
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
    stdout_start_offset: u64,
    stderr_start_offset: u64,
    stdout_next_offset: u64,
    stderr_next_offset: u64,
    stdout_bytes: u64,
    stderr_bytes: u64,

    pub fn deinit(self: LogsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const ListItem = struct {
    job_id: JobId,
    program: []const u8,
    args: []const []const u8,
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
    program: []u8,
    args: [][]u8,
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
        allocator.free(self.program);
        freeArgs(allocator, self.args);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child_environ: std.process.Environ.Map,
    mutex: std.Io.Mutex = .init,
    jobs: std.AutoHashMap(JobId, *Job),
    next_id: JobId = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: anytype) !Manager {
        var child_environ = try environ_map.clone(allocator);
        errdefer child_environ.deinit();
        _ = child_environ.swapRemove(secrets.device_token_environment);
        _ = child_environ.swapRemove(secrets.oauth_admin_pin_environment);
        _ = child_environ.swapRemove(secrets.oauth_jwt_secret_environment);

        return .{
            .allocator = allocator,
            .io = io,
            .child_environ = child_environ,
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
        self.child_environ.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Manager, input: StartInput) !StartResult {
        if (input.program.len == 0) return error.EmptyProgram;

        // Jobs outlive the request that created them, so request-owned strings
        // are copied into the manager allocator.
        const program = try self.allocator.dupe(u8, input.program);
        errdefer self.allocator.free(program);
        const args = try dupeArgs(self.allocator, input.args);
        errdefer freeArgs(self.allocator, args);

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
            .program = program,
            .args = args,
            .cwd = cwd,
            .stdout = stdout,
            .stderr = stderr,
        };

        // A successful start means the OS process has already been created.
        var child = try spawnDirectProcess(self.allocator, self.io, &self.child_environ, input.program, input.args, input.cwd);
        var child_owned = true;
        errdefer if (child_owned) process_tree.terminate(&child, self.io);

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

        events.record(self.io, .agent, "job.started", .job, job_id, input.program);
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
        stdout_after: ?u64,
        stderr_after: ?u64,
    ) !LogsResult {
        const job = try self.getJob(job_id);

        job.mutex.lockUncancelable(job.io);
        defer job.mutex.unlock(job.io);

        const stdout_range = try job.stdout.readAfter(stdout_after);
        const stderr_range = try job.stderr.readAfter(stderr_after);

        // Copy only the requested retained range while holding the lock so the
        // response never aliases a tail buffer that the worker can mutate.
        const stdout_copy = try allocator.dupe(u8, stdout_range.bytes);
        errdefer allocator.free(stdout_copy);
        const stderr_copy = try allocator.dupe(u8, stderr_range.bytes);

        return .{
            .job_id = job.id,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .stdout_truncated = stdout_range.truncated,
            .stderr_truncated = stderr_range.truncated,
            .stdout_start_offset = stdout_range.start_offset,
            .stderr_start_offset = stderr_range.start_offset,
            .stdout_next_offset = stdout_range.next_offset,
            .stderr_next_offset = stderr_range.next_offset,
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
                .program = job.program,
                .args = job.args,
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

    defer if (child_active) process_tree.terminate(&child, io);

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
            process_tree.terminate(&child, io);
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
        .program = job.program,
        .args = job.args,
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

fn dupeArgs(allocator: std.mem.Allocator, args: []const []const u8) ![][]u8 {
    const copied = try allocator.alloc([]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (copied[0..initialized]) |arg| allocator.free(arg);
        allocator.free(copied);
    }
    for (args, copied) |arg, *dest| {
        dest.* = try allocator.dupe(u8, arg);
        initialized += 1;
    }
    return copied;
}

fn freeArgs(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn spawnDirectProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    program: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
) !std.process.Child {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = program;
    @memcpy(argv[1..], args);
    return spawnProcess(io, argv, cwd, environ_map);
}

fn spawnProcess(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    environ_map: *const std.process.Environ.Map,
) !std.process.Child {
    var spawn_options: std.process.SpawnOptions = .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // On Linux this makes the direct child the leader of its own process
        // group, so job_stop can terminate the complete descendant tree.
        .pgid = if (builtin.os.tag == .linux) 0 else null,
    };
    if (cwd) |value| spawn_options.cwd = .{ .path = value };
    return std.process.spawn(io, spawn_options);
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

test "direct process job preserves argv boundaries" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var manager = try Manager.init(allocator, std.testing.io, &environ);
    defer manager.deinit();

    const started = try manager.start(.{
        .program = "/usr/bin/printf",
        .args = &.{ "<%s>", "hello world" },
    });

    var finished = false;
    for (0..100) |_| {
        const current = try manager.status(started.job_id);
        if (current.status != .running) {
            finished = true;
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(finished);

    const logs = try manager.logs(allocator, started.job_id, null, null);
    defer logs.deinit(allocator);
    try std.testing.expectEqualStrings("<hello world>", logs.stdout);
    try std.testing.expectEqualStrings("", logs.stderr);
}
