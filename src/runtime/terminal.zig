const std = @import("std");
const builtin = @import("builtin");

pub const backend_name = switch (builtin.os.tag) {
    .linux => "pty",
    .windows => "conpty",
    else => "unsupported",
};

pub const default_cols: u16 = 120;
pub const default_rows: u16 = 30;

pub const PlatformHandle = switch (builtin.os.tag) {
    .windows => *anyopaque,
    else => void,
};

pub const SpawnInput = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cols: u16 = default_cols,
    rows: u16 = default_rows,
};

pub const Spawned = struct {
    child: std.process.Child,
    input: std.Io.File,
    output: std.Io.File,
    platform: PlatformHandle,
};

pub fn defaultShell(environ_map: *const std.process.Environ.Map) []const u8 {
    return switch (builtin.os.tag) {
        .linux => environ_map.get("SHELL") orelse "/bin/bash",
        .windows => "powershell.exe",
        else => "/bin/sh",
    };
}

pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    input: SpawnInput,
) !Spawned {
    if (input.program.len == 0) return error.EmptyShell;
    if (input.cols == 0 or input.rows == 0) return error.InvalidTerminalSize;
    return switch (builtin.os.tag) {
        .linux => spawnLinux(allocator, io, environ_map, input),
        .windows => spawnWindows(allocator, environ_map, input),
        else => error.UnsupportedPlatform,
    };
}

pub fn resize(input: std.Io.File, platform: PlatformHandle, cols: u16, rows: u16) !void {
    if (cols == 0 or rows == 0) return error.InvalidTerminalSize;
    switch (builtin.os.tag) {
        .linux => try resizeLinux(input.handle, cols, rows),
        .windows => try resizeWindows(platform, cols, rows),
        else => return error.UnsupportedPlatform,
    }
}

pub fn closePlatform(platform: PlatformHandle) void {
    switch (builtin.os.tag) {
        .windows => Windows.ClosePseudoConsole(platform),
        else => {},
    }
}

/// On Windows, closing the ConPTY after its client process exits is required
/// to make the host-side output pipe reach EOF. POSIX PTYs naturally hang up
/// when the slave side disappears, so no explicit probe is needed there.
pub fn processExited(child: *const std.process.Child) bool {
    return switch (builtin.os.tag) {
        .windows => Windows.processExited(child),
        else => false,
    };
}

fn spawnLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    input: SpawnInput,
) !Spawned {
    const linux = std.os.linux;

    const executable = try resolveLinuxExecutable(allocator, io, environ_map, input.program);
    defer allocator.free(executable);

    const argv = try buildPosixArgv(allocator, input.program, input.args);
    defer freePosixArgv(allocator, argv);

    var env_block = try environ_map.createPosixBlock(allocator, .{});
    defer env_block.deinit(allocator);

    const cwd_z = if (input.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
    defer if (cwd_z) |cwd| allocator.free(cwd);

    const master = try linuxOpen(
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
    );
    errdefer linuxClose(master);

    var unlock: c_int = 0;
    try linuxIoctl(master, LinuxIoctl.TIOCSPTLCK, @intFromPtr(&unlock));

    var pty_number: c_uint = 0;
    try linuxIoctl(master, LinuxIoctl.TIOCGPTN, @intFromPtr(&pty_number));

    var slave_path_buf: [64]u8 = undefined;
    const slave_path = try std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{pty_number});
    const slave = try linuxOpen(
        slave_path,
        .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
    );
    errdefer linuxClose(slave);

    try resizeLinux(slave, input.cols, input.rows);

    const fork_result = linux.fork();
    switch (linux.errno(fork_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.TerminalSpawnFailed,
    }

    if (fork_result == 0) {
        linuxChildMain(
            master,
            slave,
            executable.ptr,
            argv.ptr,
            env_block.slice.ptr,
            if (cwd_z) |cwd| cwd.ptr else null,
        );
    }

    const pid: std.posix.pid_t = @intCast(fork_result);
    linuxClose(slave);

    const input_fd = try linuxDup(master);
    errdefer linuxClose(input_fd);

    return .{
        .child = .{
            .id = pid,
            .thread_handle = {},
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        },
        .input = .{ .handle = input_fd, .flags = .{ .nonblocking = false } },
        .output = .{ .handle = master, .flags = .{ .nonblocking = false } },
        .platform = {},
    };
}

fn linuxChildMain(
    master: std.os.linux.fd_t,
    slave: std.os.linux.fd_t,
    executable: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    const linux = std.os.linux;

    linuxClose(master);
    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(126);
    if (linux.errno(linux.ioctl(slave, LinuxIoctl.TIOCSCTTY, 0)) != .SUCCESS) linux.exit(126);

    inline for (.{ 0, 1, 2 }) |target| {
        if (linux.errno(linux.dup2(slave, target)) != .SUCCESS) linux.exit(126);
    }
    if (slave > 2) linuxClose(slave);

    if (cwd) |path| {
        if (linux.errno(linux.chdir(path)) != .SUCCESS) linux.exit(126);
    }

    _ = linux.execve(executable, argv, envp);
    linux.exit(127);
}

fn resizeLinux(fd: std.os.linux.fd_t, cols: u16, rows: u16) !void {
    var size: std.posix.winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    try linuxIoctl(fd, LinuxIoctl.TIOCSWINSZ, @intFromPtr(&size));
}

const LinuxIoctl = struct {
    // Values used by Linux asm-generic. The currently supported zshell Linux
    // targets (x86/x86_64/arm/aarch64/riscv/loongarch) share these values.
    const TIOCSCTTY: u32 = 0x540E;
    const TIOCSWINSZ: u32 = 0x5414;
    const TIOCGPTN: u32 = 0x80045430;
    const TIOCSPTLCK: u32 = 0x40045431;
};

fn linuxOpen(path: [*:0]const u8, flags: std.os.linux.O) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const rc = linux.open(path, flags, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.TerminalSpawnFailed,
    };
}

fn linuxDup(fd: std.os.linux.fd_t) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const rc = linux.dup(fd);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.TerminalSpawnFailed,
    };
}

fn linuxIoctl(fd: std.os.linux.fd_t, request: u32, arg: usize) !void {
    const linux = std.os.linux;
    const rc = linux.ioctl(fd, request, arg);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        else => return error.TerminalIoctlFailed,
    }
}

fn linuxClose(fd: std.os.linux.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn resolveLinuxExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    program: []const u8,
) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const resolved = try allocator.dupeZ(u8, program);
        errdefer allocator.free(resolved);
        if (std.fs.path.isAbsolute(program)) {
            try std.Io.Dir.accessAbsolute(io, program, .{ .execute = true });
        } else {
            try std.Io.Dir.cwd().access(io, program, .{ .execute = true });
        }
        return resolved;
    }

    const path_value = environ_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_value, ':');
    while (it.next()) |entry| {
        const base = if (entry.len == 0) "." else entry;
        const candidate = try std.fs.path.joinZ(allocator, &.{ base, program });
        errdefer allocator.free(candidate);
        const ok = if (std.fs.path.isAbsolute(candidate)) blk: {
            std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
                allocator.free(candidate);
                continue;
            };
            break :blk true;
        } else blk: {
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch {
                allocator.free(candidate);
                continue;
            };
            break :blk true;
        };
        if (ok) return candidate;
    }
    return error.FileNotFound;
}

fn buildPosixArgv(
    allocator: std.mem.Allocator,
    program: []const u8,
    args: []const []const u8,
) ![:null]?[*:0]const u8 {
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len + 1, null);
    var initialized: usize = 0;
    errdefer {
        for (argv[0..initialized]) |arg| allocator.free(std.mem.span(arg.?));
        allocator.free(argv);
    }

    const arg0 = try allocator.dupeZ(u8, program);
    argv[0] = arg0.ptr;
    initialized = 1;
    for (args, 1..) |arg, i| {
        const copy = try allocator.dupeZ(u8, arg);
        argv[i] = copy.ptr;
        initialized += 1;
    }
    return argv;
}

fn freePosixArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]const u8) void {
    for (argv) |arg| allocator.free(std.mem.span(arg.?));
    allocator.free(argv);
}

const Windows = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const HPCON = *anyopaque;
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

    const STARTUPINFOEXW = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };

    extern "kernel32" fn CreatePseudoConsole(
        size: windows.COORD,
        input: windows.HANDLE,
        output: windows.HANDLE,
        flags: windows.DWORD,
        pc: *HPCON,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(pc: HPCON, size: windows.COORD) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(pc: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(
        list: ?*anyopaque,
        attribute_count: windows.DWORD,
        flags: windows.DWORD,
        size: *windows.SIZE_T,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(
        list: *anyopaque,
        flags: windows.DWORD,
        attribute: windows.DWORD_PTR,
        value: *anyopaque,
        size: windows.SIZE_T,
        previous_value: ?*anyopaque,
        return_size: ?*windows.SIZE_T,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;

    fn processExited(child: *const std.process.Child) bool {
        const handle = child.id orelse return true;
        const zero_timeout: windows.LARGE_INTEGER = 0;
        return switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &zero_timeout)) {
            windows.NTSTATUS.WAIT_0 => true,
            .TIMEOUT => false,
            else => false,
        };
    }

    fn createPipe(inbound: bool, outbound: bool, async_server: bool) ![2]windows.HANDLE {
        var device: windows.HANDLE = undefined;
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        const device_name = windows.UNICODE_STRING.init(
            &.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'a', 'm', 'e', 'd', 'P', 'i', 'p', 'e', '\\' },
        );
        const open_status = windows.ntdll.NtOpenFile(
            &device,
            .{ .STANDARD = .{ .SYNCHRONIZE = true } },
            &.{ .ObjectName = @constCast(&device_name) },
            &iosb,
            .VALID_FLAGS,
            .{ .IO = .SYNCHRONOUS_NONALERT },
        );
        if (open_status != .SUCCESS) return error.WindowsPipeFailed;
        defer windows.CloseHandle(device);

        var server: windows.HANDLE = undefined;
        const create_status = windows.ntdll.NtCreateNamedPipeFile(
            &server,
            .{
                .SPECIFIC = .{ .FILE_PIPE = .{
                    .READ_DATA = inbound,
                    .WRITE_DATA = outbound,
                    .WRITE_ATTRIBUTES = true,
                } },
                .STANDARD = .{ .SYNCHRONIZE = !async_server },
            },
            &.{ .RootDirectory = device },
            &iosb,
            .{ .READ = true, .WRITE = true },
            .CREATE,
            .{ .IO = if (async_server) .ASYNCHRONOUS else .SYNCHRONOUS_NONALERT },
            .{ .TYPE = .BYTE_STREAM },
            .{ .MODE = .BYTE_STREAM },
            .{ .OPERATION = .QUEUE },
            1,
            if (inbound) 4096 else 0,
            if (outbound) 4096 else 0,
            null,
        );
        if (create_status != .SUCCESS) return error.WindowsPipeFailed;
        errdefer windows.CloseHandle(server);

        var client: windows.HANDLE = undefined;
        const client_status = windows.ntdll.NtOpenFile(
            &client,
            .{
                .SPECIFIC = .{ .FILE_PIPE = .{
                    .READ_DATA = outbound,
                    .WRITE_DATA = inbound,
                    .WRITE_ATTRIBUTES = true,
                } },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            &.{ .RootDirectory = server },
            &iosb,
            .{ .READ = true, .WRITE = true },
            .{ .IO = .SYNCHRONOUS_NONALERT },
        );
        if (client_status != .SUCCESS) return error.WindowsPipeFailed;
        return .{ server, client };
    }
} else struct {};

fn spawnWindows(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    input: SpawnInput,
) !Spawned {
    const windows = std.os.windows;

    const input_pipe = try Windows.createPipe(false, true, false);
    errdefer for (input_pipe) |handle| windows.CloseHandle(handle);
    const output_pipe = try Windows.createPipe(true, false, true);
    errdefer for (output_pipe) |handle| windows.CloseHandle(handle);

    var hpcon: Windows.HPCON = undefined;
    const create_hr = Windows.CreatePseudoConsole(
        .{ .X = @intCast(input.cols), .Y = @intCast(input.rows) },
        input_pipe[1],
        output_pipe[1],
        0,
        &hpcon,
    );
    if (create_hr < 0) return error.CreatePseudoConsoleFailed;
    var hpcon_owned = true;
    errdefer if (hpcon_owned) Windows.ClosePseudoConsole(hpcon);

    // ConPTY owns the client ends after creation; the host keeps only the
    // opposite ends used by shell_write/shell_read.
    windows.CloseHandle(input_pipe[1]);
    windows.CloseHandle(output_pipe[1]);

    var attr_size: windows.SIZE_T = 0;
    _ = Windows.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    if (attr_size == 0) return error.InitializePseudoConsoleAttributesFailed;
    const attr_mem = try allocator.alignedAlloc(u8, .of(usize), attr_size);
    defer allocator.free(attr_mem);
    const attr_list: *anyopaque = @ptrCast(attr_mem.ptr);
    if (Windows.InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == .FALSE) {
        return error.InitializePseudoConsoleAttributesFailed;
    }
    defer Windows.DeleteProcThreadAttributeList(attr_list);

    var hpcon_value = hpcon;
    if (Windows.UpdateProcThreadAttribute(
        attr_list,
        0,
        Windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        @ptrCast(&hpcon_value),
        @sizeOf(Windows.HPCON),
        null,
        null,
    ) == .FALSE) return error.UpdatePseudoConsoleAttributesFailed;

    const command_line_utf8 = try buildWindowsCommandLine(allocator, input.program, input.args);
    defer allocator.free(command_line_utf8);
    const command_line = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_line_utf8);
    defer allocator.free(command_line);

    const cwd_w = if (input.cwd) |cwd| try std.unicode.wtf8ToWtf16LeAllocZ(allocator, cwd) else null;
    defer if (cwd_w) |cwd| allocator.free(cwd);

    var env_block = try environ_map.createWindowsBlock(allocator, .{});
    defer env_block.deinit(allocator);

    var startup: Windows.STARTUPINFOEXW = .{
        .StartupInfo = .{
            .cb = @sizeOf(Windows.STARTUPINFOEXW),
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .dwFlags = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
            .hStdInput = null,
            .hStdOutput = null,
            .hStdError = null,
        },
        .lpAttributeList = attr_list,
    };
    var process_info: windows.PROCESS.INFORMATION = undefined;
    const created = windows.kernel32.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        .FALSE,
        .{ .extended_startupinfo_present = true, .create_unicode_environment = true },
        env_block.slice.ptr,
        if (cwd_w) |cwd| cwd.ptr else null,
        @ptrCast(&startup.StartupInfo),
        &process_info,
    );
    if (created == .FALSE) return error.CreateProcessFailed;
    hpcon_owned = false;

    return .{
        .child = .{
            .id = process_info.hProcess,
            .thread_handle = process_info.hThread,
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        },
        .input = .{ .handle = input_pipe[0], .flags = .{ .nonblocking = false } },
        .output = .{ .handle = output_pipe[0], .flags = .{ .nonblocking = true } },
        .platform = hpcon,
    };
}

fn resizeWindows(platform: PlatformHandle, cols: u16, rows: u16) !void {
    const hr = Windows.ResizePseudoConsole(platform, .{ .X = @intCast(cols), .Y = @intCast(rows) });
    if (hr < 0) return error.ResizePseudoConsoleFailed;
}

fn buildWindowsCommandLine(
    allocator: std.mem.Allocator,
    program: []const u8,
    args: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try appendWindowsArg(&out.writer, program);
    for (args) |arg| {
        try out.writer.writeByte(' ');
        try appendWindowsArg(&out.writer, arg);
    }
    return out.toOwnedSlice();
}

fn appendWindowsArg(writer: *std.Io.Writer, arg: []const u8) !void {
    const needs_quotes = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
    if (!needs_quotes) return writer.writeAll(arg);

    try writer.writeByte('"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        if (ch == '"') {
            for (0..backslashes * 2 + 1) |_| try writer.writeByte('\\');
            try writer.writeByte('"');
            backslashes = 0;
            continue;
        }
        for (0..backslashes) |_| try writer.writeByte('\\');
        backslashes = 0;
        try writer.writeByte(ch);
    }
    for (0..backslashes * 2) |_| try writer.writeByte('\\');
    try writer.writeByte('"');
}

test "windows command line quoting preserves simple boundaries" {
    const allocator = std.testing.allocator;
    const value = try buildWindowsCommandLine(allocator, "pwsh.exe", &.{ "-NoLogo", "hello world", "a\\\"b" });
    defer allocator.free(value);
    try std.testing.expectEqualStrings("pwsh.exe -NoLogo \"hello world\" \"a\\\\\\\"b\"", value);
}
