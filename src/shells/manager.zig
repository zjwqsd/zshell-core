const std = @import("std");
const builtin = @import("builtin");
const secrets = @import("../runtime/secrets.zig");

const TailBuffer = @import("../jobs/tail_buffer.zig").TailBuffer;
const events = @import("../control/events.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const output_buffer_bytes: usize = 1024 * 1024;
pub const poll_interval_ms: i64 = 100;
pub const backend_name = "pipe";

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
    cwd: ?[]const u8 = null,
};

pub const StartResult = struct {
    shell_id: ShellId,
    initial_cwd: ?[]const u8,
    status: Status,
    backend: []const u8 = backend_name,
};

pub const WriteResult = struct {
    shell_id: ShellId,
    sent_bytes: usize,
    enter: bool,
};

pub const ReadResult = struct {
    shell_id: ShellId,
    initial_cwd: ?[]const u8,
    status: Status,
    exit_code: ?u8,
    termination: ?[]const u8,
    worker_error: ?[]const u8,
    termination_source: ?Source,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
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
    initial_cwd: ?[]const u8,
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
    initial_cwd: ?[]u8,

    mutex: std.Io.Mutex = .init,
    input_mutex: std.Io.Mutex = .init,

    status: Status = .running,
    exit_code: ?u8 = null,
    termination: ?[]const u8 = null,
    worker_error: ?[]const u8 = null,
    termination_source: ?Source = null,
    stop_requested: ?Source = null,

    stdin: std.Io.File,
    stdin_open: bool = true,

    stdout: TailBuffer,
    stderr: TailBuffer,

    thread: ?std.Thread = null,
    thread_claimed: bool = false,

    fn deinit(self: *Shell, allocator: std.mem.Allocator) void {
        if (self.stdin_open) self.stdin.close(self.io);
        if (self.initial_cwd) |cwd| allocator.free(cwd);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    shells: std.AutoHashMap(ShellId, *Shell),
    next_id: ShellId = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{
            .allocator = allocator,
            .io = io,
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
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }

        self.shells.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Manager, input: StartInput) !StartResult {
        const cwd = if (input.cwd) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        var cwd_owned = true;
        errdefer if (cwd_owned) {
            if (cwd) |value| self.allocator.free(value);
        };

        var stdout = try TailBuffer.init(self.allocator, output_buffer_bytes);
        var stdout_owned = true;
        errdefer if (stdout_owned) stdout.deinit(self.allocator);

        var stderr = try TailBuffer.init(self.allocator, output_buffer_bytes);
        var stderr_owned = true;
        errdefer if (stderr_owned) stderr.deinit(self.allocator);

        var child = try spawnPersistentShell(self.io, input.cwd);
        var child_owned = true;
        errdefer if (child_owned) child.kill(self.io);

        const stdin = child.stdin.?;
        child.stdin = null;
        var stdin_owned = true;
        errdefer if (stdin_owned) stdin.close(self.io);

        // ShellCore connection secrets belong to the service process, not to child
        // shells. Remove them before this persistent shell becomes observable
        // or writable by remote callers.
        if (builtin.os.tag != .windows) {
            try stdin.writeStreamingAll(self.io, secrets.posix_clear ++ "\n");
        }

        const shell = try self.allocator.create(Shell);
        var shell_initialized = false;
        errdefer if (shell_initialized)
            shell.deinit(self.allocator)
        else
            self.allocator.destroy(shell);

        self.mutex.lockUncancelable(self.io);
        const shell_id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock(self.io);

        shell.* = .{
            .id = shell_id,
            .io = self.io,
            .initial_cwd = cwd,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
        };
        shell_initialized = true;
        cwd_owned = false;
        stdin_owned = false;
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

        const thread = try std.Thread.spawn(
            .{},
            workerMain,
            .{WorkerContext{
                .io = self.io,
                .allocator = self.allocator,
                .shell = shell,
                .child = child,
            }},
        );
        child_owned = false;

        shell.mutex.lockUncancelable(shell.io);
        shell.thread = thread;
        shell.mutex.unlock(shell.io);

        events.record(self.io, .agent, "shell.started", .shell, shell_id, "persistent shell started");
        return .{
            .shell_id = shell_id,
            .initial_cwd = shell.initial_cwd,
            .status = .running,
        };
    }

    pub fn write(
        self: *Manager,
        shell_id: ShellId,
        input: []const u8,
        enter: bool,
    ) !WriteResult {
        const shell = try self.getShell(shell_id);

        shell.mutex.lockUncancelable(shell.io);
        const running =
            shell.status == .running and
            shell.stop_requested == null;
        shell.mutex.unlock(shell.io);

        if (!running) {
            return error.ShellNotRunning;
        }

        shell.input_mutex.lockUncancelable(shell.io);
        defer shell.input_mutex.unlock(shell.io);

        if (!shell.stdin_open) {
            return error.ShellNotRunning;
        }

        switch (builtin.os.tag) {
            .windows => try writeWindowsInput(
                self.allocator,
                shell.stdin,
                shell.io,
                input,
                enter,
            ),

            else => {
                try shell.stdin.writeStreamingAll(
                    shell.io,
                    input,
                );

                if (enter) {
                    try shell.stdin.writeStreamingAll(
                        shell.io,
                        "\n",
                    );
                }
            },
        }

        events.record(self.io, .agent, "shell.write", .shell, shell_id, input);

        return .{
            .shell_id = shell_id,
            .sent_bytes = input.len,
            .enter = enter,
        };
    }

    pub fn read(
        self: *Manager,
        allocator: std.mem.Allocator,
        shell_id: ShellId,
    ) !ReadResult {
        const shell = try self.getShell(shell_id);
        reapFinishedThread(shell);

        shell.mutex.lockUncancelable(shell.io);
        defer shell.mutex.unlock(shell.io);

        const stdout_copy = try allocator.dupe(u8, shell.stdout.slice());
        errdefer allocator.free(stdout_copy);
        const stderr_copy = try allocator.dupe(u8, shell.stderr.slice());

        return .{
            .shell_id = shell.id,
            .initial_cwd = shell.initial_cwd,
            .status = shell.status,
            .exit_code = shell.exit_code,
            .termination = shell.termination,
            .worker_error = shell.worker_error,
            .termination_source = shell.termination_source,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .stdout_truncated = shell.stdout.truncated(),
            .stderr_truncated = shell.stderr.truncated(),
            .stdout_bytes = shell.stdout.total_bytes,
            .stderr_bytes = shell.stderr.total_bytes,
        };
    }

    pub fn kill(self: *Manager, shell_id: ShellId, source: Source) LookupError!KillResult {
        const shell = try self.getShell(shell_id);

        shell.mutex.lockUncancelable(shell.io);
        if (shell.status == .running and shell.stop_requested == null) {
            shell.stop_requested = source;
        }
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
                .initial_cwd = shell.initial_cwd,
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

    defer if (child_active) {
        closeInput(shell);
        child.kill(io);
    };

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
        drainBuffered(shell, stdout_reader, stderr_reader);

        if (stopSource(shell)) |source| {
            closeInput(shell);
            child.kill(io);
            child_active = false;
            drainBuffered(shell, stdout_reader, stderr_reader);
            setKilled(shell, source);
            events.record(io, source, "shell.killed", .shell, shell.id, "killed");
            return;
        }

        multi_reader.fill(1, poll_timeout) catch |err| switch (err) {
            error.EndOfStream => {
                drainBuffered(shell, stdout_reader, stderr_reader);
                break;
            },
            error.Timeout => continue,
            else => return err,
        };
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    child_active = false;
    closeInput(shell);
    setTerminated(shell, term);
    events.record(io, .process, "shell.exited", .shell, shell.id, terminationFromTerm(term));
}

fn drainBuffered(
    shell: *Shell,
    stdout_reader: *std.Io.Reader,
    stderr_reader: *std.Io.Reader,
) void {
    const stdout = stdout_reader.buffered();
    const stderr = stderr_reader.buffered();
    if (stdout.len == 0 and stderr.len == 0) return;

    shell.mutex.lockUncancelable(shell.io);
    shell.stdout.append(stdout);
    shell.stderr.append(stderr);
    shell.mutex.unlock(shell.io);

    stdout_reader.tossBuffered();
    stderr_reader.tossBuffered();
}

fn stopSource(shell: *Shell) ?Source {
    shell.mutex.lockUncancelable(shell.io);
    defer shell.mutex.unlock(shell.io);
    return shell.stop_requested;
}

fn closeInput(shell: *Shell) void {
    shell.input_mutex.lockUncancelable(shell.io);
    defer shell.input_mutex.unlock(shell.io);

    if (!shell.stdin_open) return;
    shell.stdin.close(shell.io);
    shell.stdin_open = false;
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

    if (!finished) return;
    if (claimThread(shell)) |thread| thread.join();
}

fn spawnPersistentShell(
    io: std.Io,
    cwd: ?[]const u8,
) !std.process.Child {
    return switch (builtin.os.tag) {
        .windows => spawnWindowsShell(
            io,
            cwd,
        ),

        else => spawnProcess(
            io,
            &.{
                "/bin/sh",
            },
            cwd,
        ),
    };
}

fn spawnWindowsShell(
    io: std.Io,
    cwd: ?[]const u8,
) !std.process.Child {
    const bootstrap =
        secrets.powershell_clear ++
        "$__zshell_utf8 = [System.Text.UTF8Encoding]::new($false); " ++
        "[Console]::OutputEncoding = $__zshell_utf8; " ++
        "$OutputEncoding = $__zshell_utf8; " ++
        "$__zshell_input = [Console]::OpenStandardInput(); " ++
        "$__zshell_reader = " ++
        "[System.IO.StreamReader]::new(" ++
        "$__zshell_input, " ++
        "[System.Text.Encoding]::ASCII, " ++
        "$false, 4096, $true); " ++
        "$__zshell_pending = ''; " ++
        "while (($__zshell_frame = " ++
        "$__zshell_reader.ReadLine()) -ne $null) { " ++
        "if ($__zshell_frame.Length -lt 2 -or " ++
        "$__zshell_frame[1] -ne ':') { continue }; " ++
        "$__zshell_enter = " ++
        "$__zshell_frame[0] -eq '1'; " ++
        "$__zshell_payload = " ++
        "$__zshell_frame.Substring(2); " ++
        "$__zshell_bytes = " ++
        "[Convert]::FromBase64String(" ++
        "$__zshell_payload); " ++
        "$__zshell_pending += " ++
        "$__zshell_utf8.GetString(" ++
        "$__zshell_bytes); " ++
        "if ($__zshell_enter) { " ++
        "try { " ++
        "Invoke-Expression $__zshell_pending " ++
        "} catch { " ++
        "Write-Error $_ " ++
        "} finally { " ++
        "$__zshell_pending = '' " ++
        "} " ++
        "} " ++
        "}";

    return spawnProcess(
        io,
        &.{
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            bootstrap,
        },
        cwd,
    );
}

fn spawnProcess(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !std.process.Child {
    if (cwd) |value| {
        return std.process.spawn(
            io,
            .{
                .argv = argv,

                .cwd = .{
                    .path = value,
                },

                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
            },
        );
    }

    return std.process.spawn(
        io,
        .{
            .argv = argv,

            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        },
    );
}

fn writeWindowsInput(
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    io: std.Io,
    input: []const u8,
    enter: bool,
) !void {
    const encoded_size =
        std.base64.standard.Encoder.calcSize(
            input.len,
        );

    const encoded =
        try allocator.alloc(
            u8,
            encoded_size,
        );
    defer allocator.free(
        encoded,
    );

    _ = std.base64.standard.Encoder.encode(
        encoded,
        input,
    );

    //
    // Internal pipe protocol:
    //
    //     0:<base64>\n
    //     1:<base64>\n
    //
    // 0 = append only
    // 1 = append and execute
    //
    const prefix =
        if (enter)
            "1:"
        else
            "0:";

    try stdin.writeStreamingAll(
        io,
        prefix,
    );

    try stdin.writeStreamingAll(
        io,
        encoded,
    );

    try stdin.writeStreamingAll(
        io,
        "\n",
    );
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
