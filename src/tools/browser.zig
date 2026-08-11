const std = @import("std");
const builtin = @import("builtin");

pub const session_name = "zshell-core";
pub const namespace_name = "zshell";
pub const max_capture_bytes: u64 = 8 * 1024 * 1024;

pub const Mode = enum {
    temporary,
    persistent,
    chrome_profile,

    pub fn name(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const Owner = enum {
    agent,
    human,

    pub fn name(self: Owner) []const u8 {
        return @tagName(self);
    }
};

pub const StartInput = struct {
    mode: Mode = .temporary,
    visible: bool = false,
    profile: ?[]const u8 = null,
};

pub const Status = struct {
    available: bool,
    active: bool,
    mode: ?[]const u8,
    visible: bool,
    owner: []const u8,
    profile: ?[]const u8,
    dataDir: []const u8,
    agentBrowserExecutable: ?[]const u8,
    browserExecutable: ?[]const u8,
};

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    success: bool,
    valid_json: bool,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Error = error{
    BrowserUnavailable,
    BrowserAlreadyActive,
    BrowserNotActive,
    BrowserHumanControlActive,
    BrowserMustBeVisible,
    BrowserSessionLost,
    InvalidBrowserEncryptionKey,
    InvalidProfileName,
    ProfileRequired,
};

const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []u8,
    child_environ: std.process.Environ.Map,
    agent_browser_executable: ?[]u8,
    browser_executable: ?[]u8,
    capture_id: u64 = 1,

    active: bool = false,
    mode: Mode = .temporary,
    visible: bool = false,
    owner: Owner = .agent,
    profile_label: ?[]u8 = null,
    profile_arg: ?[]u8 = null,

    fn deinit(self: *Manager) void {
        if (self.active) {
            if (self.runSessionCommand(self.allocator, &.{"close"})) |result| {
                result.deinit(self.allocator);
            } else |_| {}
        }
        self.clearSessionState();
        if (self.agent_browser_executable) |value| self.allocator.free(value);
        if (self.browser_executable) |value| self.allocator.free(value);
        self.child_environ.deinit();
        self.allocator.free(self.data_dir);
        self.* = undefined;
    }

    fn clearSessionState(self: *Manager) void {
        if (self.profile_label) |value| self.allocator.free(value);
        if (self.profile_arg) |value| self.allocator.free(value);
        self.profile_label = null;
        self.profile_arg = null;
        self.active = false;
        self.mode = .temporary;
        self.visible = false;
        self.owner = .agent;
    }

    fn currentStatus(self: *const Manager) Status {
        return .{
            .available = self.agent_browser_executable != null,
            .active = self.active,
            .mode = if (self.active) self.mode.name() else null,
            .visible = self.active and self.visible,
            .owner = if (self.active) self.owner.name() else Owner.agent.name(),
            .profile = if (self.active) self.profile_label else null,
            .dataDir = self.data_dir,
            .agentBrowserExecutable = self.agent_browser_executable,
            .browserExecutable = self.browser_executable,
        };
    }

    fn start(self: *Manager, allocator: std.mem.Allocator, input: StartInput) !CommandResult {
        if (self.active) return Error.BrowserAlreadyActive;
        if (self.agent_browser_executable == null) return Error.BrowserUnavailable;

        // Clean a stale session left by a previous ShellCore crash. Persistent
        // authentication state lives in the profile, not in this daemon session.
        if (self.runSessionCommand(allocator, &.{"close"})) |stale| {
            stale.deinit(allocator);
        } else |_| {}

        var profile_label: ?[]u8 = null;
        errdefer if (profile_label) |value| allocator.free(value);
        var profile_arg: ?[]u8 = null;
        errdefer if (profile_arg) |value| allocator.free(value);

        switch (input.mode) {
            .temporary => {
                if (input.profile != null) return Error.InvalidProfileName;
            },
            .persistent => {
                try self.ensureEncryptionKey();
                const label = input.profile orelse "default";
                if (!isSafeProfileName(label)) return Error.InvalidProfileName;
                profile_label = try allocator.dupe(u8, label);

                const profiles_dir = try std.fs.path.join(allocator, &.{ self.data_dir, "profiles" });
                defer allocator.free(profiles_dir);
                try std.Io.Dir.cwd().createDirPath(self.io, profiles_dir);

                profile_arg = try std.fs.path.join(allocator, &.{ profiles_dir, label });
                try std.Io.Dir.cwd().createDirPath(self.io, profile_arg.?);
            },
            .chrome_profile => {
                const label = input.profile orelse return Error.ProfileRequired;
                if (label.len == 0 or label.len > 128) return Error.InvalidProfileName;
                profile_label = try allocator.dupe(u8, label);
                profile_arg = try allocator.dupe(u8, label);
            },
        }

        const use_discovered_browser = input.mode != .chrome_profile;
        const restore_key: ?[]const u8 = if (input.mode == .persistent) profile_label else null;
        var result = try self.runLaunchCommand(allocator, input.visible, profile_arg, restore_key, use_discovered_browser, &.{"open"});
        var retry_index: usize = 0;
        const retry_delays_ms = [_]i64{ 200, 500 };
        while (!result.success and
            responseIndicatesTransientDaemonRace(allocator, result.stdout) and
            retry_index < retry_delays_ms.len)
        {
            result.deinit(allocator);
            try self.io.sleep(.fromMilliseconds(retry_delays_ms[retry_index]), .awake);
            retry_index += 1;
            result = try self.runLaunchCommand(allocator, input.visible, profile_arg, restore_key, use_discovered_browser, &.{"open"});
        }

        if (result.success) {
            self.mode = input.mode;
            self.visible = input.visible;
            self.owner = .agent;
            self.profile_label = profile_label;
            self.profile_arg = profile_arg;
            self.active = true;
            profile_label = null;
            profile_arg = null;
        } else {
            if (profile_label) |value| allocator.free(value);
            if (profile_arg) |value| allocator.free(value);
            profile_label = null;
            profile_arg = null;
        }
        return result;
    }

    fn ensureEncryptionKey(self: *Manager) !void {
        if (self.child_environ.get("AGENT_BROWSER_ENCRYPTION_KEY")) |existing| {
            if (!isEncryptionKey(existing)) return Error.InvalidBrowserEncryptionKey;
            return;
        }

        try std.Io.Dir.cwd().createDirPath(self.io, self.data_dir);
        const key_path = try std.fs.path.join(self.allocator, &.{ self.data_dir, "restore.key" });
        defer self.allocator.free(key_path);

        var key_bytes: [64]u8 = undefined;
        const key: []const u8 = blk: {
            var file = std.Io.Dir.openFileAbsolute(self.io, key_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    var random: [32]u8 = undefined;
                    self.io.random(&random);
                    const digits = "0123456789abcdef";
                    for (random, 0..) |byte, index| {
                        key_bytes[index * 2] = digits[byte >> 4];
                        key_bytes[index * 2 + 1] = digits[byte & 0x0f];
                    }

                    const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows)
                        .default_file
                    else
                        std.Io.Dir.Permissions.fromMode(0o600);
                    var created = try std.Io.Dir.createFileAbsolute(self.io, key_path, .{
                        .read = true,
                        .exclusive = true,
                        .permissions = permissions,
                    });
                    defer created.close(self.io);
                    try created.writeStreamingAll(self.io, &key_bytes);
                    break :blk key_bytes[0..];
                },
                else => return err,
            };
            defer file.close(self.io);
            const info = try file.stat(self.io);
            if (info.size > 128) return Error.InvalidBrowserEncryptionKey;
            var stored: [128]u8 = undefined;
            const size: usize = @intCast(info.size);
            const read_len = try file.readPositionalAll(self.io, stored[0..size], 0);
            if (read_len != size) return Error.InvalidBrowserEncryptionKey;
            const trimmed = std.mem.trim(u8, stored[0..size], " \t\r\n");
            if (!isEncryptionKey(trimmed)) return Error.InvalidBrowserEncryptionKey;
            @memcpy(&key_bytes, trimmed);
            break :blk key_bytes[0..];
        };

        try self.child_environ.put("AGENT_BROWSER_ENCRYPTION_KEY", key);
    }

    fn requireAgent(self: *const Manager) Error!void {
        if (!self.active) return Error.BrowserNotActive;
        if (self.owner == .human) return Error.BrowserHumanControlActive;
    }

    fn command(self: *Manager, allocator: std.mem.Allocator, args: []const []const u8) !CommandResult {
        try self.requireAgent();
        try self.ensureSessionAlive(allocator);

        const result = try self.runSessionCommand(allocator, args);
        if ((!result.success and responseIndicatesSessionLoss(allocator, result.stdout)) or
            (result.success and responseIndicatesUnexpectedRelaunch(allocator, result.stdout)))
        {
            result.deinit(allocator);
            self.clearSessionState();
            return Error.BrowserSessionLost;
        }
        return result;
    }

    fn takeover(self: *Manager, owner: Owner) Error!Status {
        if (!self.active) return Error.BrowserNotActive;
        if (owner == .human and !self.visible) return Error.BrowserMustBeVisible;
        self.owner = owner;
        return self.currentStatus();
    }

    fn close(self: *Manager, allocator: std.mem.Allocator) !CommandResult {
        try self.requireAgent();
        const result = try self.runSessionCommand(allocator, &.{"close"});
        if (result.success) self.clearSessionState();
        return result;
    }

    fn runLaunchCommand(
        self: *Manager,
        allocator: std.mem.Allocator,
        visible: bool,
        profile: ?[]const u8,
        restore_key: ?[]const u8,
        use_discovered_browser: bool,
        command_args: []const []const u8,
    ) !CommandResult {
        const executable = self.agent_browser_executable orelse return Error.BrowserUnavailable;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, executable);
        try argv.appendSlice(allocator, &.{ "--namespace", namespace_name, "--session", session_name });
        if (use_discovered_browser) {
            if (self.browser_executable) |browser_path| {
                try argv.appendSlice(allocator, &.{ "--executable-path", browser_path });
            }
        }
        if (profile) |profile_value| {
            try argv.appendSlice(allocator, &.{ "--profile", profile_value });
        }
        if (restore_key) |key| {
            try argv.appendSlice(allocator, &.{ "--restore", key });
        }
        if (visible) {
            try argv.appendSlice(allocator, &.{ "--headed", "true" });
        }
        try argv.appendSlice(allocator, command_args);
        try argv.append(allocator, "--json");
        return self.runArgv(allocator, argv.items);
    }

    fn ensureSessionAlive(self: *Manager, allocator: std.mem.Allocator) !void {
        // Verify the same browser process still exists before every Agent action.
        // This prevents agent-browser auto-launch from silently replacing a lost
        // session with a fresh empty browser whose refs and login context differ.
        const info = try self.runSessionCommand(allocator, &.{ "session", "info" });
        defer info.deinit(allocator);
        if (!info.success or !sessionInfoHasBrowser(allocator, info.stdout)) {
            self.clearSessionState();
            return Error.BrowserSessionLost;
        }
    }

    fn runSessionCommand(
        self: *Manager,
        allocator: std.mem.Allocator,
        command_args: []const []const u8,
    ) !CommandResult {
        const executable = self.agent_browser_executable orelse return Error.BrowserUnavailable;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        try argv.appendSlice(allocator, &.{ executable, "--namespace", namespace_name, "--session", session_name });
        try argv.appendSlice(allocator, command_args);
        try argv.append(allocator, "--json");
        return self.runArgv(allocator, argv.items);
    }

    fn runArgv(
        self: *Manager,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
    ) !CommandResult {
        const capture_dir = try std.fs.path.join(allocator, &.{ self.data_dir, "tmp" });
        defer allocator.free(capture_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, capture_dir);

        const id = self.capture_id;
        self.capture_id +%= 1;
        const stdout_path = try std.fmt.allocPrint(allocator, "{s}{c}capture-{d}.stdout", .{ capture_dir, std.fs.path.sep, id });
        defer allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(allocator, "{s}{c}capture-{d}.stderr", .{ capture_dir, std.fs.path.sep, id });
        defer allocator.free(stderr_path);

        var stdout_file = try std.Io.Dir.createFileAbsolute(self.io, stdout_path, .{ .read = true, .truncate = true });
        var stdout_open = true;
        defer if (stdout_open) stdout_file.close(self.io);
        var stderr_file = try std.Io.Dir.createFileAbsolute(self.io, stderr_path, .{ .read = true, .truncate = true });
        var stderr_open = true;
        defer if (stderr_open) stderr_file.close(self.io);

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = stdout_file },
            .stderr = .{ .file = stderr_file },
            .environ_map = &self.child_environ,
            .create_no_window = builtin.os.tag == .windows,
        });
        const term = try child.wait(self.io);

        const stdout = try readCapture(allocator, self.io, stdout_file);
        errdefer allocator.free(stdout);
        const stderr = try readCapture(allocator, self.io, stderr_file);
        errdefer allocator.free(stderr);

        stdout_file.close(self.io);
        stdout_open = false;
        stderr_file.close(self.io);
        stderr_open = false;
        std.Io.Dir.deleteFileAbsolute(self.io, stdout_path) catch {};
        std.Io.Dir.deleteFileAbsolute(self.io, stderr_path) catch {};
        std.Io.Dir.deleteDirAbsolute(self.io, capture_dir) catch {};
        if (self.mode == .temporary) std.Io.Dir.deleteDirAbsolute(self.io, self.data_dir) catch {};

        const inspected = inspectJsonSuccess(allocator, stdout);
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .term = term,
            .success = inspected.success,
            .valid_json = inspected.valid_json,
        };
    }
};

const InspectResult = struct {
    success: bool,
    valid_json: bool,
};

var global_manager: ?Manager = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: anytype) !void {
    std.debug.assert(global_manager == null);

    const data_dir = try resolveDataDir(allocator, environ_map);
    errdefer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    var child_environ = try environ_map.clone(allocator);
    errdefer child_environ.deinit();
    _ = child_environ.swapRemove("ZSHELL_DEVICE_TOKEN");
    _ = child_environ.swapRemove("ZSHELL_OAUTH_ADMIN_PIN");
    _ = child_environ.swapRemove("ZSHELL_OAUTH_JWT_SECRET");

    const agent_browser_executable = try discoverAgentBrowserExecutable(allocator, io, environ_map);
    errdefer if (agent_browser_executable) |value| allocator.free(value);
    const browser_executable = try discoverBrowserExecutable(allocator, io, environ_map);
    errdefer if (browser_executable) |value| allocator.free(value);

    global_manager = .{
        .allocator = allocator,
        .io = io,
        .data_dir = data_dir,
        .child_environ = child_environ,
        .agent_browser_executable = agent_browser_executable,
        .browser_executable = browser_executable,
    };
}

pub fn deinit() void {
    if (global_manager) |*manager| {
        manager.deinit();
        global_manager = null;
    }
}

pub fn status() Status {
    return getManager().currentStatus();
}

pub fn start(allocator: std.mem.Allocator, input: StartInput) !CommandResult {
    return getManager().start(allocator, input);
}

pub fn command(allocator: std.mem.Allocator, args: []const []const u8) !CommandResult {
    return getManager().command(allocator, args);
}

pub fn takeover(owner: Owner) Error!Status {
    return getManager().takeover(owner);
}

pub fn close(allocator: std.mem.Allocator) !CommandResult {
    return getManager().close(allocator);
}

fn getManager() *Manager {
    if (global_manager) |*manager| return manager;
    @panic("browser subsystem is not initialized");
}

fn sessionInfoHasBrowser(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .object => |value| value,
        else => return false,
    };
    const runtime_value = data.get("runtime") orelse return false;
    const runtime = switch (runtime_value) {
        .object => |value| value,
        else => return false,
    };

    if (runtime.get("effectiveLaunch")) |launch_value| {
        const launch = switch (launch_value) {
            .object => |value| value,
            else => return false,
        };
        if (launch.get("browserLaunched")) |launched_value| {
            if (launched_value == .bool and launched_value.bool) return true;
        }
    }
    if (runtime.get("pageCount")) |page_count| {
        if (page_count == .integer and page_count.integer > 0) return true;
    }
    return false;
}

fn responseIndicatesUnexpectedRelaunch(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const data_value = root.get("data") orelse return false;
    const data = switch (data_value) {
        .object => |value| value,
        else => return false,
    };
    const lifecycle_value = data.get("lifecycle") orelse return false;
    const lifecycle = switch (lifecycle_value) {
        .object => |value| value,
        else => return false,
    };
    if (lifecycle.get("launched")) |value| {
        if (value == .bool and value.bool) return true;
    }
    if (lifecycle.get("relaunchedBrowser")) |value| {
        if (value == .bool and value.bool) return true;
    }
    return false;
}

fn responseIndicatesTransientDaemonRace(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const error_value = root.get("error") orelse return false;
    const message = switch (error_value) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.indexOf(u8, message, "Failed to connect") != null;
}

fn responseIndicatesSessionLoss(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const error_value = root.get("error") orelse return false;
    const message = switch (error_value) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.indexOf(u8, message, "Auto-launch failed") != null;
}

fn inspectJsonSuccess(allocator: std.mem.Allocator, bytes: []const u8) InspectResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return .{ .success = false, .valid_json = false };
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return .{ .success = false, .valid_json = true },
    };
    const success_value = object.get("success") orelse return .{ .success = false, .valid_json = true };
    return switch (success_value) {
        .bool => |flag| .{ .success = flag, .valid_json = true },
        else => .{ .success = false, .valid_json = true },
    };
}

fn readCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) ![]u8 {
    const info = try file.stat(io);
    if (info.size > max_capture_bytes) return error.AgentBrowserOutputTooLarge;
    const size: usize = @intCast(info.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    const read_len = try file.readPositionalAll(io, bytes, 0);
    if (read_len != size) return error.AgentBrowserCaptureShortRead;
    return bytes;
}

fn isEncryptionKey(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isSafeProfileName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

fn resolveDataDir(allocator: std.mem.Allocator, environ_map: anytype) ![]u8 {
    if (environ_map.get("ZSHELL_BROWSER_DATA_DIR")) |value| {
        if (value.len == 0) return error.InvalidBrowserDataDirectory;
        return allocator.dupe(u8, value);
    }

    return switch (builtin.os.tag) {
        .windows => blk: {
            const base = environ_map.get("LOCALAPPDATA") orelse
                environ_map.get("USERPROFILE") orelse return error.MissingBrowserDataDirectory;
            break :blk try std.fs.path.join(allocator, &.{ base, "zshell", "browser" });
        },
        .macos => blk: {
            const home = environ_map.get("HOME") orelse return error.MissingBrowserDataDirectory;
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "zshell", "browser" });
        },
        else => blk: {
            if (environ_map.get("XDG_DATA_HOME")) |base| {
                break :blk try std.fs.path.join(allocator, &.{ base, "zshell", "browser" });
            }
            const home = environ_map.get("HOME") orelse return error.MissingBrowserDataDirectory;
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "zshell", "browser" });
        },
    };
}

fn discoverAgentBrowserExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: anytype,
) !?[]u8 {
    if (environ_map.get("ZSHELL_AGENT_BROWSER_EXECUTABLE")) |configured| {
        if (configured.len == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, configured));
    }

    const path_value = environ_map.get("PATH") orelse return null;
    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var paths = std.mem.splitScalar(u8, path_value, delimiter);
    while (paths.next()) |directory| {
        if (directory.len == 0) continue;

        if (builtin.os.tag == .windows) {
            if (builtin.cpu.arch == .x86_64) {
                const npm_native = try std.fs.path.join(allocator, &.{
                    directory,
                    "node_modules",
                    "agent-browser",
                    "bin",
                    "agent-browser-win32-x64.exe",
                });
                if (pathExists(io, npm_native)) return npm_native;
                allocator.free(npm_native);
            }

            const direct_exe = try std.fs.path.join(allocator, &.{ directory, "agent-browser.exe" });
            if (pathExists(io, direct_exe)) return direct_exe;
            allocator.free(direct_exe);
        } else {
            const direct = try std.fs.path.join(allocator, &.{ directory, "agent-browser" });
            if (pathExists(io, direct)) return direct;
            allocator.free(direct);
        }
    }
    return null;
}

fn discoverBrowserExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: anytype,
) !?[]u8 {
    if (environ_map.get("ZSHELL_BROWSER_EXECUTABLE")) |configured| {
        if (configured.len == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, configured));
    }

    if (builtin.os.tag != .windows) return null;

    if (environ_map.get("PROGRAMFILES")) |base| {
        if (try candidateUnder(allocator, io, base, &.{ "Google", "Chrome", "Application", "chrome.exe" })) |path| return path;
        if (try candidateUnder(allocator, io, base, &.{ "Microsoft", "Edge", "Application", "msedge.exe" })) |path| return path;
    }
    if (environ_map.get("PROGRAMFILES(X86)")) |base| {
        if (try candidateUnder(allocator, io, base, &.{ "Google", "Chrome", "Application", "chrome.exe" })) |path| return path;
        if (try candidateUnder(allocator, io, base, &.{ "Microsoft", "Edge", "Application", "msedge.exe" })) |path| return path;
    }
    if (environ_map.get("LOCALAPPDATA")) |base| {
        if (try candidateUnder(allocator, io, base, &.{ "Google", "Chrome", "Application", "chrome.exe" })) |path| return path;
    }
    return null;
}

fn candidateUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    parts: []const []const u8,
) !?[]u8 {
    var joined_parts: std.ArrayList([]const u8) = .empty;
    defer joined_parts.deinit(allocator);
    try joined_parts.append(allocator, base);
    try joined_parts.appendSlice(allocator, parts);
    const candidate = try std.fs.path.join(allocator, joined_parts.items);
    if (pathExists(io, candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

test "human takeover blocks agent until explicit return" {
    const allocator = std.testing.allocator;
    const data_dir = try allocator.dupe(u8, ".");
    defer allocator.free(data_dir);

    var manager = Manager{
        .allocator = allocator,
        .io = std.testing.io,
        .data_dir = data_dir,
        .child_environ = std.process.Environ.Map.init(allocator),
        .agent_browser_executable = null,
        .browser_executable = null,
        .active = true,
        .visible = true,
    };

    defer manager.child_environ.deinit();

    const handed = try manager.takeover(.human);
    try std.testing.expectEqualStrings("human", handed.owner);
    try std.testing.expectError(Error.BrowserHumanControlActive, manager.requireAgent());

    const resumed = try manager.takeover(.agent);
    try std.testing.expectEqualStrings("agent", resumed.owner);
    try manager.requireAgent();
}

test "human takeover requires visible browser" {
    const allocator = std.testing.allocator;
    const data_dir = try allocator.dupe(u8, ".");
    defer allocator.free(data_dir);

    var manager = Manager{
        .allocator = allocator,
        .io = std.testing.io,
        .data_dir = data_dir,
        .child_environ = std.process.Environ.Map.init(allocator),
        .agent_browser_executable = null,
        .browser_executable = null,
        .active = true,
        .visible = false,
    };
    defer manager.child_environ.deinit();
    try std.testing.expectError(Error.BrowserMustBeVisible, manager.takeover(.human));
}

test "browser encryption key validation" {
    try std.testing.expect(isEncryptionKey("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isEncryptionKey("short"));
    try std.testing.expect(!isEncryptionKey("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "profile names reject path traversal" {
    try std.testing.expect(isSafeProfileName("default"));
    try std.testing.expect(isSafeProfileName("school-2026"));
    try std.testing.expect(!isSafeProfileName("../default"));
    try std.testing.expect(!isSafeProfileName("school/profile"));
    try std.testing.expect(!isSafeProfileName(""));
}
