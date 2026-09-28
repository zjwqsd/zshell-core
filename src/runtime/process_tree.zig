const std = @import("std");
const builtin = @import("builtin");

const WindowsApi = if (builtin.os.tag == .windows) struct {
    const wait_object_0: std.os.windows.DWORD = 0x00000000;
    const taskkill_timeout_ms: std.os.windows.DWORD = 2_000;

    extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
    extern "kernel32" fn WaitForSingleObject(
        handle: std.os.windows.HANDLE,
        milliseconds: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;
    extern "kernel32" fn TerminateProcess(
        process: std.os.windows.HANDLE,
        exit_code: std.os.windows.UINT,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// Terminate a spawned command and the descendants that belong to its managed
/// process tree/process group.
pub fn terminate(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) {
        child.kill(io);
        return;
    }

    switch (builtin.os.tag) {
        .windows => terminateWindowsTree(child, io),
        .linux, .macos => terminatePosixGroup(child, io),
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

        // taskkill is best-effort process-tree cleanup. Never let a stuck
        // taskkill.exe turn an exec timeout into a permanently wedged
        // ShellCore request loop.
        if (killer.id) |killer_handle| {
            const wait_result = WindowsApi.WaitForSingleObject(killer_handle, WindowsApi.taskkill_timeout_ms);
            if (wait_result != WindowsApi.wait_object_0) {
                _ = WindowsApi.TerminateProcess(killer_handle, 1);
            }
        }
        _ = killer.wait(io) catch {};
    }

    // taskkill closes the process tree, while Child.kill() finishes cleanup of
    // Zig's direct-child handle and remains a safe fallback if taskkill failed.
    child.kill(io);
}

fn terminatePosixGroup(child: *std.process.Child, io: std.Io) void {
    const pid = child.id orelse return;

    // Managed POSIX children are launched in a dedicated process group whose
    // group ID equals the child PID. A negative PID addresses that whole group.
    std.posix.kill(-pid, .KILL) catch {};

    // Reap/clean up the direct child handle. This is also a fallback if the group
    // signal failed because the child had already exited.
    child.kill(io);
}
