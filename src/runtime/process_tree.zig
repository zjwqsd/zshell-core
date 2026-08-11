const std = @import("std");
const builtin = @import("builtin");

const WindowsApi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
} else struct {};

/// Spawn managed commands in their own process group on Linux so descendants
/// can be terminated together with the direct child.
pub fn spawnProcessGroup() ?std.posix.pid_t {
    return if (builtin.os.tag == .linux) 0 else null;
}

/// Terminate a spawned command and the descendants that belong to its managed
/// process tree/process group.
pub fn terminate(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) {
        child.kill(io);
        return;
    }

    switch (builtin.os.tag) {
        .windows => terminateWindowsTree(child, io),
        .linux => terminateLinuxGroup(child, io),
        else => child.kill(io),
    }
}

fn terminateWindowsTree(child: *std.process.Child, io: std.Io) void {
    const handle = child.id orelse return;
    const pid = WindowsApi.GetProcessId(handle);
    if (pid != 0) {
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch {
            child.kill(io);
            return;
        };

        var killer = std.process.spawn(io, .{
            .argv = &.{ "taskkill.exe", "/PID", pid_text, "/T", "/F" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch {
            child.kill(io);
            return;
        };
        _ = killer.wait(io) catch {};
    }

    // taskkill closes the process tree, while Child.kill() finishes cleanup of
    // Zig's direct-child handle and remains a safe fallback if taskkill failed.
    child.kill(io);
}

fn terminateLinuxGroup(child: *std.process.Child, io: std.Io) void {
    const pid = child.id orelse return;

    // Managed Linux children are spawned with pgid=0, which makes the child the
    // leader of a fresh process group. A negative PID addresses that whole group.
    std.posix.kill(-pid, .KILL) catch {};

    // Reap/clean up the direct child handle. This is also a fallback if the group
    // signal failed because the child had already exited.
    child.kill(io);
}
