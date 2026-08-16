const std = @import("std");
const zshell = @import("root.zig");
const tui = @import("tui/app.zig");
const attach = @import("tui/attach.zig");

var log_io: ?std.Io = null;

pub const std_options: std.Options = .{
    .logFn = eventLog,
};

pub fn main(init: std.process.Init) !void {
    zshell.runtime.session_process.runIfRequested(init);
    log_io = init.io;

    const browser_enabled = try parseBrowserOption(init);
    zshell.tools.browser.init(init.gpa, init.io, init.environ_map, browser_enabled) catch |err| {
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

    if (browser_enabled) {
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

fn parseBrowserOption(init: std.process.Init) !bool {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var enabled = false;
    var browser_seen = false;
    var no_browser_seen = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--browser")) {
            if (no_browser_seen) return error.ConflictingBrowserOptions;
            enabled = true;
            browser_seen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-browser")) {
            if (browser_seen) return error.ConflictingBrowserOptions;
            enabled = false;
            no_browser_seen = true;
            continue;
        }
        return error.UnknownCommandLineArgument;
    }

    return enabled;
}

fn eventLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = log_io orelse return;
    _ = scope;

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
