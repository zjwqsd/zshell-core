const std = @import("std");
const builtin = @import("builtin");
const process_tree = @import("../runtime/process_tree.zig");
const terminal = @import("../runtime/terminal.zig");
const secrets = @import("../runtime/secrets.zig");

const TailBuffer = @import("../jobs/tail_buffer.zig").TailBuffer;
const events = @import("../control/events.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const output_buffer_bytes: usize = 1024 * 1024;
pub const poll_interval_ms: i64 = 100;
pub const backend_name = terminal.backend_name;

pub const ShellId = u64;

pub const Status = enum {
    running,
    exited,
    killed,
    failed,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const StartInput = struct {
    shell: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cols: u16 = terminal.default_cols,
    rows: u16 = terminal.default_rows,
};

pub const StartResult = struct {
    shell_id: ShellId,
    shell: []const u8,
    args: []const []const u8,
    initial_cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    status: Status,
    backend: []const u8 = backend_name,
};

pub const WriteResult = struct {
    shell_id: ShellId,
    sent_bytes: usize,
    enter: bool,
};

pub const ResizeResult = struct {
    shell_id: ShellId,
    cols: u16,
    rows: u16,
};

pub const ReadResult = struct {
    shell_id: ShellId,
    shell: []const u8,
    args: []const []const u8,
    initial_cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    status: Status,
    exit_code: ?u8,
    termination: ?[]const u8,
    worker_error: ?[]const u8,
    termination_source: ?Source,
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

    pub fn deinit(self: ReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const KillResult = struct {
    shell_id: ShellId,
    status: Status,
    exit_code: ?u8,
    termination: ?[]const u8,
    worker_error: ?[]const u8,
    termination_source: ?Source,
};

pub const ListItem = struct {
    shell_id: ShellId,
    shell: []const u8,
    args: []const []const u8,
    initial_cwd: ?[]const u8,
    cols: u16,
    rows: u16,
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

pub const LookupError = error{ShellNotFound};
pub const Error = LookupError || error{ShellNotRunning};

const Shell = struct {
    id: ShellId,
    io: std.Io,
    shell: []u8,
    args: [][]u8,
    initial_cwd: ?[]u8,
    cols: u16,
    rows: u16,

    mutex: std.Io.Mutex = .init,
    input_mutex: std.Io.Mutex = .init,

    status: Status = .running,
    exit_code: ?u8 = null,
    termination: ?[]const u8 = null,
    worker_error: ?[]const u8 = null,
    termination_source: ?Source = null,
    stop_requested: ?Source = null,

    input: std.Io.File,
    input_open: bool = true,
    platform: terminal.PlatformHandle,
    platform_open: bool = true,

    // PTY/ConPTY has one terminal output stream. Keep stderr as an empty tail
    // buffer so the protocol remains backwards compatible.
    stdout: TailBuffer,
    stderr: TailBuffer,

    thread: ?std.Thread = null,
    thread_claimed: bool = false,

    fn deinit(self: *Shell, allocator: std.mem.Allocator) void {
        if (self.input_open) self.input.close(self.io);
        if (self.platform_open) terminal.closePlatform(self.platform);
        allocator.free(self.shell);
        freeArgs(allocator, self.args);
        if (self.initial_cwd) |cwd| allocator.free(cwd);
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
    shells: std.AutoHashMap(ShellId, *Shell),
    next_id: ShellId = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: anytype) !Manager {
        var child_environ = try environ_map.clone(allocator);
        errdefer child_environ.deinit();
        scrubChildEnvironment(&child_environ);
        if (builtin.os.tag == .linux and child_environ.get("TERM") == null) {
            try child_environ.put("TERM", "xterm-256color");
        }
        return .{
            .allocator = allocator,
            .io = io,
            .child_environ = child_environ,
            .shells = std.AutoHashMap(ShellId, *Shell).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.shells.iterator();
        while (iterator.next()) |entry| {
            const shell = entry.value_ptr.*;
            shell.mutex.lockUncancelable(shell.io);
            if (shell.status == .running and shell.stop_requested == null) shell.stop_requested = .system;
            shell.mutex.unlock(shell.io);
        }

        iterator = self.shells.iterator();
        while (iterator.next()) |entry| {
            if (claimThread(entry.value_ptr.*)) |thread| thread.join();
        }

        iterator = self.shells.iterator();
        while (iterator.next()) |entry| entry.value_ptr.*.deinit(self.allocator);

        self.shells.deinit();
        self.child_environ.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Manager, input: StartInput) !StartResult {
        if (input.cols == 0 or input.rows == 0) return error.InvalidTerminalSize;
        const selected_shell = input.shell orelse terminal.defaultShell(&self.child_environ);
        if (selected_shell.len == 0) return error.EmptyShell;

        const shell_name = try self.allocator.dupe(u8, selected_shell);
        var shell_name_owned = true;
        errdefer if (shell_name_owned) self.allocator.free(shell_name);

        const args = try dupeArgs(self.allocator, input.args);
        var args_owned = true;
        errdefer if (args_owned) freeArgs(self.allocator, args);

        const cwd = if (input.cwd) |value| try self.allocator.dupe(u8, value) else null;
        var cwd_owned = true;
        errdefer if (cwd_owned) if (cwd) |value| self.allocator.free(value);

        var stdout = try TailBuffer.init(self.allocator, output_buffer_bytes);
        var stdout_owned = true;
        errdefer if (stdout_owned) stdout.deinit(self.allocator);

        var stderr = try TailBuffer.init(self.allocator, output_buffer_bytes);
        var stderr_owned = true;
        errdefer if (stderr_owned) stderr.deinit(self.allocator);

        var spawned = try terminal.spawn(self.allocator, self.io, &self.child_environ, .{
            .program = selected_shell,
            .args = input.args,
            .cwd = input.cwd,
            .cols = input.cols,
            .rows = input.rows,
        });
        var child_owned = true;
        var input_owned = true;
        var output_owned = true;
        var platform_owned = true;
        errdefer {
            if (child_owned) process_tree.terminate(&spawned.child, self.io);
            if (input_owned) spawned.input.close(self.io);
            if (output_owned) spawned.output.close(self.io);
            if (platform_owned) terminal.closePlatform(spawned.platform);
        }

        const shell = try self.allocator.create(Shell);
        var shell_initialized = false;
        errdefer if (shell_initialized) shell.deinit(self.allocator) else self.allocator.destroy(shell);

        self.mutex.lockUncancelable(self.io);
        const shell_id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock(self.io);

        shell.* = .{
            .id = shell_id,
            .io = self.io,
            .shell = shell_name,
            .args = args,
            .initial_cwd = cwd,
            .cols = input.cols,
            .rows = input.rows,
            .input = spawned.input,
            .platform = spawned.platform,
            .stdout = stdout,
            .stderr = stderr,
        };
        shell_initialized = true;
        shell_name_owned = false;
        args_owned = false;
        cwd_owned = false;
        input_owned = false;
        platform_owned = false;
        stdout_owned = false;
        stderr_owned = false;

        self.mutex.lockUncancelable(self.io);
        self.shells.put(shell_id, shell) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        errdefer {
            self.mutex.lockUncancelable(self.io);
            _ = self.shells.remove(shell_id);
            self.mutex.unlock(self.io);
        }

        const thread = try std.Thread.spawn(.{}, workerMain, .{WorkerContext{
            .io = self.io,
            .allocator = self.allocator,
            .shell = shell,
            .child = spawned.child,
            .output = spawned.output,
        }});
        child_owned = false;
        output_owned = false;

        shell.mutex.lockUncancelable(shell.io);
        shell.thread = thread;
        shell.mutex.unlock(shell.io);

        events.record(self.io, .agent, "shell.started", .shell, shell_id, selected_shell);
        return .{
            .shell_id = shell_id,
            .shell = shell.shell,
            .args = shell.args,
            .initial_cwd = shell.initial_cwd,
            .cols = shell.cols,
            .rows = shell.rows,
            .status = .running,
        };
    }

    pub fn write(self: *Manager, shell_id: ShellId, input: []const u8, enter: bool) !WriteResult {
        const shell = try self.getShell(shell_id);
        shell.mutex.lockUncancelable(shell.io);
        const running = shell.status == .running and shell.stop_requested == null;
        shell.mutex.unlock(shell.io);
        if (!running) return error.ShellNotRunning;

        shell.input_mutex.lockUncancelable(shell.io);
        defer shell.input_mutex.unlock(shell.io);
        if (!shell.input_open) return error.ShellNotRunning;

        try shell.input.writeStreamingAll(shell.io, input);
        // A terminal Enter key is carriage return. POSIX line discipline maps
        // it to newline; ConPTY accepts it as the normal Enter input sequence.
        if (enter) try shell.input.writeStreamingAll(shell.io, "\r");

        events.record(self.io, .agent, "shell.write", .shell, shell_id, input);
        return .{ .shell_id = shell_id, .sent_bytes = input.len, .enter = enter };
    }

    pub fn resize(self: *Manager, shell_id: ShellId, cols: u16, rows: u16) !ResizeResult {
        const shell = try self.getShell(shell_id);
        if (cols == 0 or rows == 0) return error.InvalidTerminalSize;

        shell.input_mutex.lockUncancelable(shell.io);
        defer shell.input_mutex.unlock(shell.io);
        shell.mutex.lockUncancelable(shell.io);
        defer shell.mutex.unlock(shell.io);
        if (shell.status != .running or !shell.input_open or !shell.platform_open) return error.ShellNotRunning;

        try terminal.resize(shell.input, shell.platform, cols, rows);
        shell.cols = cols;
        shell.rows = rows;
        return .{ .shell_id = shell_id, .cols = cols, .rows = rows };
    }

    pub fn read(
        self: *Manager,
        allocator: std.mem.Allocator,
        shell_id: ShellId,
        stdout_after: ?u64,
        stderr_after: ?u64,
    ) !ReadResult {
        const shell = try self.getShell(shell_id);
        reapFinishedThread(shell);

        shell.mutex.lockUncancelable(shell.io);
        defer shell.mutex.unlock(shell.io);
        const stdout_range = try shell.stdout.readAfter(stdout_after);
        const stderr_range = try shell.stderr.readAfter(stderr_after);
        const stdout_copy = try allocator.dupe(u8, stdout_range.bytes);
        errdefer allocator.free(stdout_copy);
        const stderr_copy = try allocator.dupe(u8, stderr_range.bytes);

        return .{
            .shell_id = shell.id,
            .shell = shell.shell,
            .args = shell.args,
            .initial_cwd = shell.initial_cwd,
            .cols = shell.cols,
            .rows = shell.rows,
            .status = shell.status,
            .exit_code = shell.exit_code,
            .termination = shell.termination,
            .worker_error = shell.worker_error,
            .termination_source = shell.termination_source,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .stdout_truncated = stdout_range.truncated,
            .stderr_truncated = stderr_range.truncated,
            .stdout_start_offset = stdout_range.start_offset,
            .stderr_start_offset = stderr_range.start_offset,
            .stdout_next_offset = stdout_range.next_offset,
            .stderr_next_offset = stderr_range.next_offset,
            .stdout_bytes = shell.stdout.total_bytes,
            .stderr_bytes = shell.stderr.total_bytes,
        };
    }

    pub fn kill(self: *Manager, shell_id: ShellId, source: Source) LookupError!KillResult {
        const shell = try self.getShell(shell_id);
        shell.mutex.lockUncancelable(shell.io);
        if (shell.status == .running and shell.stop_requested == null) shell.stop_requested = source;
        shell.mutex.unlock(shell.io);

        if (claimThread(shell)) |thread| thread.join();

        shell.mutex.lockUncancelable(shell.io);
        defer shell.mutex.unlock(shell.io);
        return .{
            .shell_id = shell.id,
            .status = shell.status,
            .exit_code = shell.exit_code,
            .termination = shell.termination,
            .worker_error = shell.worker_error,
            .termination_source = shell.termination_source,
        };
    }

    pub fn list(self: *Manager, allocator: std.mem.Allocator) !ListResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const items = try allocator.alloc(ListItem, self.shells.count());
        errdefer allocator.free(items);

        var index: usize = 0;
        var iterator = self.shells.iterator();
        while (iterator.next()) |entry| {
            const shell = entry.value_ptr.*;
            shell.mutex.lockUncancelable(shell.io);
            items[index] = .{
                .shell_id = shell.id,
                .shell = shell.shell,
                .args = shell.args,
                .initial_cwd = shell.initial_cwd,
                .cols = shell.cols,
                .rows = shell.rows,
                .status = shell.status,
                .exit_code = shell.exit_code,
                .termination_source = shell.termination_source,
            };
            shell.mutex.unlock(shell.io);
            index += 1;
        }
        return .{ .items = items };
    }

    fn getShell(self: *Manager, shell_id: ShellId) LookupError!*Shell {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.shells.get(shell_id) orelse error.ShellNotFound;
    }
};

const WorkerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    shell: *Shell,
    child: std.process.Child,
    output: std.Io.File,
};

fn workerMain(context: WorkerContext) void {
    runWorker(context) catch |err| {
        const shell = context.shell;
        shell.mutex.lockUncancelable(shell.io);
        shell.status = .failed;
        shell.worker_error = @errorName(err);
        shell.termination = "worker_error";
        shell.termination_source = .system;
        shell.mutex.unlock(shell.io);
        events.record(shell.io, .system, "shell.failed", .shell, shell.id, @errorName(err));
    };
}

fn runWorker(context: WorkerContext) !void {
    const io = context.io;
    const shell = context.shell;
    var child = context.child;
    var child_active = true;
    var stopping_source: ?Source = null;
    var platform_close_thread: ?std.Thread = null;

    defer context.output.close(io);
    defer if (platform_close_thread) |thread| thread.join();
    defer if (child_active) {
        process_tree.terminate(&child, io);
        closeInput(shell);
        closePlatform(shell);
    };

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(context.allocator, io, multi_reader_buffer.toStreams(), &.{context.output});
    defer multi_reader.deinit();
    const output_reader = multi_reader.reader(0);
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromMilliseconds(poll_interval_ms), .clock = .awake },
    };

    while (true) {
        drainBuffered(shell, output_reader);

        if (stopping_source == null) {
            if (stopSource(shell)) |source| {
                process_tree.terminate(&child, io);
                child_active = false;
                closeInput(shell);
                try beginPlatformClose(shell, &platform_close_thread);
                stopping_source = source;
            } else if (terminal.processExited(&child)) {
                // Closing ConPTY may wait for its output pipe to be drained. Do
                // it on a helper thread while this worker keeps consuming output.
                try beginPlatformClose(shell, &platform_close_thread);
            }
        }

        if (builtin.os.tag == .linux) {
            multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
                error.EndOfStream => {
                    // File-level PTY EIO is retained by MultiReader and handled
                    // by checkAnyError below after the stream is exhausted.
                    drainBuffered(shell, output_reader);
                    break;
                },
                error.Timeout => continue,
                else => return err,
            };
        } else {
            multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
                error.EndOfStream => {
                    drainBuffered(shell, output_reader);
                    break;
                },
                error.Timeout => continue,
                else => return err,
            };
        }
    }

    if (builtin.os.tag == .linux) {
        multi_reader.checkAnyError() catch |err| switch (err) {
            error.InputOutput => {},
            else => return err,
        };
    } else {
        try multi_reader.checkAnyError();
    }

    if (platform_close_thread) |thread| {
        thread.join();
        platform_close_thread = null;
    }

    if (stopping_source) |source| {
        setKilled(shell, source);
        events.record(io, source, "shell.killed", .shell, shell.id, "killed");
        return;
    }

    const term = try child.wait(io);
    child_active = false;
    closeInput(shell);
    closePlatform(shell);
    setTerminated(shell, term);
    events.record(io, .process, "shell.exited", .shell, shell.id, terminationFromTerm(term));
}

fn beginPlatformClose(shell: *Shell, thread: *?std.Thread) !void {
    shell.mutex.lockUncancelable(shell.io);
    const open = shell.platform_open;
    shell.mutex.unlock(shell.io);
    if (!open) return;

    if (builtin.os.tag == .windows) {
        if (thread.* == null) {
            thread.* = try std.Thread.spawn(.{}, closePlatform, .{shell});
        }
    } else {
        closePlatform(shell);
    }
}

fn drainBuffered(shell: *Shell, output_reader: *std.Io.Reader) void {
    const output = output_reader.buffered();
    if (output.len == 0) return;
    shell.mutex.lockUncancelable(shell.io);
    shell.stdout.append(output);
    shell.mutex.unlock(shell.io);
    output_reader.tossBuffered();
}

fn stopSource(shell: *Shell) ?Source {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    return shell.stop_requested;
}

fn closeInput(shell: *Shell) void {
    shell.input_mutex.lockUncancelable(shell.io);
    defer shell.input_mutex.unlock(shell.io);
    if (!shell.input_open) return;
    shell.input.close(shell.io);
    shell.input_open = false;
}

fn closePlatform(shell: *Shell) void {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    if (!shell.platform_open) return;
    terminal.closePlatform(shell.platform);
    shell.platform_open = false;
}

fn setKilled(shell: *Shell, source: Source) void {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    shell.status = .killed;
    shell.exit_code = null;
    shell.termination = "killed";
    shell.termination_source = source;
}

fn setTerminated(shell: *Shell, term: std.process.Child.Term) void {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    shell.status = .exited;
    shell.exit_code = exitCodeFromTerm(term);
    shell.termination = terminationFromTerm(term);
    shell.termination_source = .process;
}

fn claimThread(shell: *Shell) ?std.Thread {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    if (shell.thread_claimed) return null;
    const thread = shell.thread orelse return null;
    shell.thread_claimed = true;
    shell.thread = null;
    return thread;
}

fn reapFinishedThread(shell: *Shell) void {
    shell.mutex.lockUncancelable(shell.io);
    const finished = shell.status != .running;
    shell.mutex.unlock(shell.io);
    if (finished) if (claimThread(shell)) |thread| thread.join();
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

fn scrubChildEnvironment(environment: *std.process.Environ.Map) void {
    _ = environment.swapRemove(secrets.device_token_environment);
    _ = environment.swapRemove(secrets.oauth_admin_pin_environment);
    _ = environment.swapRemove(secrets.oauth_jwt_secret_environment);
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

test "PTY shell is interactive persistent and resizable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try environment.put("HOME", "/tmp");
    try environment.put("SHELL", "/bin/bash");
    try environment.put("TERM", "xterm-256color");

    var manager = try Manager.init(allocator, std.testing.io, &environment);
    defer manager.deinit();

    const started = try manager.start(.{
        .shell = "/bin/bash",
        .args = &.{ "--noprofile", "--norc" },
        .cols = 80,
        .rows = 24,
    });
    try std.testing.expectEqualStrings("pty", started.backend);

    _ = try manager.write(started.shell_id, "if [ -t 0 ] && [ -t 1 ]; then printf '__PTY_OK__\\n'; fi", true);
    _ = try manager.write(started.shell_id, "export ZSHELL_PTY_STATE=works", true);
    _ = try manager.write(started.shell_id, "printf '__STATE_%s__\\n' \"$ZSHELL_PTY_STATE\"", true);
    _ = try manager.resize(started.shell_id, 100, 40);
    _ = try manager.write(started.shell_id, "printf '__SIZE_'; stty size; printf '__'", true);
    _ = try manager.write(started.shell_id, "exit", true);

    var final_read: ?ReadResult = null;
    for (0..300) |_| {
        const current = try manager.read(allocator, started.shell_id, null, null);
        if (current.status != .running) {
            final_read = current;
            break;
        }
        current.deinit(allocator);
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    const result = final_read orelse return error.TestUnexpectedResult;
    defer result.deinit(allocator);

    try std.testing.expectEqual(Status.exited, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "__PTY_OK__") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "__STATE_works__") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "__SIZE_40 100") != null);
    try std.testing.expectEqual(@as(u64, 0), result.stderr_bytes);
}

test "PTY can start zsh explicitly" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/zsh", .{ .execute = true }) catch return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try environment.put("HOME", "/tmp");
    try environment.put("SHELL", "/bin/bash");
    try environment.put("TERM", "xterm-256color");

    var manager = try Manager.init(allocator, std.testing.io, &environment);
    defer manager.deinit();

    const started = try manager.start(.{
        .shell = "/usr/bin/zsh",
        .args = &.{"-f"},
    });
    try std.testing.expectEqualStrings("/usr/bin/zsh", started.shell);
    _ = try manager.write(started.shell_id, "printf '__ZSH_%s__\\n' \"$ZSH_VERSION\"", true);
    _ = try manager.write(started.shell_id, "exit", true);

    var final_read: ?ReadResult = null;
    for (0..300) |_| {
        const current = try manager.read(allocator, started.shell_id, null, null);
        if (current.status != .running) {
            final_read = current;
            break;
        }
        current.deinit(allocator);
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    const result = final_read orelse return error.TestUnexpectedResult;
    defer result.deinit(allocator);
    try std.testing.expectEqual(Status.exited, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "__ZSH_") != null);
}
