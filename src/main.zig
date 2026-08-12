const std = @import("std");
const zshell = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const browser_enabled = try parseBrowserOption(init);

    zshell.tools.browser.init(init.gpa, init.io, init.environ_map, browser_enabled) catch |err| {
        switch (err) {
            error.AgentBrowserNotFound => std.log.err(
                "browser feature requested, but agent-browser was not found; install agent-browser or start without --browser",
                .{},
            ),
            error.ChromeNotFound => std.log.err(
                "browser feature requested, but Google Chrome/Chromium was not found; install Chrome or start without --browser",
                .{},
            ),
            else => {},
        }
        return err;
    };
    defer zshell.tools.browser.deinit();

    if (browser_enabled) {
        const status = zshell.tools.browser.status();
        std.log.info("browser feature enabled: agent-browser={s}, browser={s}", .{
            status.agentBrowserExecutable orelse "unknown",
            status.browserExecutable orelse "unknown",
        });
    } else {
        std.log.info("browser feature disabled; start with --browser to enable it", .{});
    }

    try zshell.tools.jobs.init(init.gpa, init.io, init.environ_map);
    defer zshell.tools.jobs.deinit();

    try zshell.tools.shells.init(init.gpa, init.io, init.environ_map);
    defer zshell.tools.shells.deinit();

    const human_thread = try std.Thread.spawn(
        .{},
        humanControlMain,
        .{ init.gpa, init.io },
    );
    human_thread.detach();

    try zshell.device.client.run(init.gpa, init.io, init.environ_map);
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

        std.log.err("unknown command-line argument: {s}", .{arg});
        return error.UnknownCommandLineArgument;
    }

    return enabled;
}

fn humanControlMain(allocator: std.mem.Allocator, io: std.Io) void {
    zshell.control.server.serve(allocator, io) catch |err| {
        std.log.err("human control server stopped: {s}", .{@errorName(err)});
        _ = zshell.control.state.take(io);
        zshell.control.events.record(
            io,
            .system,
            "control.server_failed",
            .control,
            null,
            @errorName(err),
        );
    };
}
