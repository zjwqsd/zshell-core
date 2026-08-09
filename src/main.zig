const std = @import("std");
const zshell = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    zshell.tools.jobs.init(init.gpa, init.io);
    defer zshell.tools.jobs.deinit();

    zshell.tools.shells.init(init.gpa, init.io);
    defer zshell.tools.shells.deinit();

    const human_thread = try std.Thread.spawn(
        .{},
        humanControlMain,
        .{ init.gpa, init.io },
    );
    human_thread.detach();

    try zshell.device.client.run(init.gpa, init.io, init.environ_map);
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
