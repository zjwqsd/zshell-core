const std = @import("std");
const builtin = @import("builtin");
const zshell = @import("root.zig");
const tui = @import("tui/app.zig");
const attach = @import("tui/attach.zig");

var log_io: ?std.Io = null;
var log_to_stderr: bool = false;

pub const std_options: std.Options = .{
    .logFn = eventLog,
};

pub fn main(init: std.process.Init) !void {
    zshell.runtime.session_process.runIfRequested(init);
    log_io = init.io;

    const options = try parseStartupOptions(init);
    if (options.daemon) try daemonize();
    log_to_stderr = options.headless;
    zshell.tools.browser.init(init.gpa, init.io, init.environ_map, options.browser_enabled) catch |err| {
        zshell.control.events.record(
            init.io,
            .system,
            "browser.init_failed",
            .shellcore,
            null,
            @errorName(err),
        );
        return err;
    };
    defer zshell.tools.browser.deinit();

    if (options.browser_enabled) {
        const status = zshell.tools.browser.status();
        const message = status.agentBrowserExecutable orelse "agent-browser";
        zshell.control.events.record(init.io, .system, "browser.enabled", .shellcore, null, message);
    } else {
        zshell.control.events.record(init.io, .system, "browser.disabled", .shellcore, null, "browser feature disabled");
    }

    try zshell.tools.jobs.init(init.gpa, init.io, init.environ_map);
    defer zshell.tools.jobs.deinit();

    try zshell.tools.shells.init(init.gpa, init.io, init.environ_map);
    defer zshell.tools.shells.deinit();

    if (options.headless) {
        zshell.control.events.record(init.io, .system, "shellcore.headless_started", .shellcore, null, "headless mode started");
        try zshell.device.client.run(init.gpa, init.io, init.environ_map);
        return;
    }

    const gateway_thread = try std.Thread.spawn(
        .{},
        gatewayMain,
        .{ init.gpa, init.io, init.environ_map },
    );
    defer {
        zshell.device.client.requestStop(init.io);
        gateway_thread.join();
    }

    zshell.control.events.record(init.io, .system, "shellcore.tui_started", .shellcore, null, "terminal UI started");

    while (true) {
        const action = try tui.run(init.gpa, init.io, init.environ_map);
        switch (action) {
            .quit => return,
            .attach => |shell_id| {
                attach.run(init.gpa, init.io, init.environ_map, shell_id) catch |err| {
                    zshell.control.events.record(
                        init.io,
                        .system,
                        "shell.attach_failed",
                        .shell,
                        shell_id,
                        @errorName(err),
                    );
                };
            },
        }
    }
}

fn gatewayMain(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
) void {
    zshell.device.client.run(allocator, io, environ_map) catch |err| {
        zshell.control.events.record(
            io,
            .system,
            "shellcore.gateway_stopped",
            .shellcore,
            null,
            @errorName(err),
        );
    };
}

const StartupOptions = struct {
    browser_enabled: bool = false,
    headless: bool = false,
    daemon: bool = false,
};

fn parseStartupOptions(init: std.process.Init) !StartupOptions {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var options: StartupOptions = .{};
    var browser_seen = false;
    var no_browser_seen = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--browser")) {
            if (no_browser_seen) return error.ConflictingBrowserOptions;
            options.browser_enabled = true;
            browser_seen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-browser")) {
            if (browser_seen) return error.ConflictingBrowserOptions;
            options.browser_enabled = false;
            no_browser_seen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--daemon")) {
            options.daemon = true;
            continue;
        }
        return error.UnknownCommandLineArgument;
    }

    if (options.headless and options.browser_enabled) return error.HeadlessBrowserUnsupported;
    if (options.daemon and !options.headless) return error.DaemonRequiresHeadless;
    return options;
}

fn daemonize() !void {
    if (comptime builtin.os.tag != .linux) return error.DaemonUnsupported;

    const linux = std.os.linux;
    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.DaemonForkFailed,
        else => return error.DaemonForkFailed,
    }

    if (fork_rc != 0) linux.exit_group(0);

    const sid_rc = linux.setsid();
    if (linux.errno(sid_rc) != .SUCCESS) return error.DaemonSetSidFailed;
}

fn eventLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = log_io orelse return;
    _ = scope;

    if (log_to_stderr) {
        std.debug.print("[{s}] " ++ format ++ "\n", .{@tagName(message_level)} ++ args);
    }

    var buffer: [zshell.control.events.message_capacity]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch "std.log message exceeded event buffer";
    const kind = switch (message_level) {
        .err => "log.error",
        .warn => "log.warning",
        .info => "log.info",
        .debug => "log.debug",
    };
    zshell.control.events.record(io, .system, kind, .shellcore, null, message);
}
