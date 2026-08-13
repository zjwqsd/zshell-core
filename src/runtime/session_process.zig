const std = @import("std");
const builtin = @import("builtin");

pub const internal_flag = "--zshell-internal-session-exec";

/// Handle the private Linux launcher mode before normal ShellCore startup.
/// The launcher becomes a new session leader and then replaces itself with the
/// requested program. This prevents managed children from sharing ShellCore's
/// controlling terminal while keeping child PID == process-group/session ID.
pub fn runIfRequested(init: std.process.Init) void {
    if (builtin.os.tag != .linux) return;

    const raw_args = init.minimal.args.vector;
    if (raw_args.len < 2) return;
    if (!std.mem.eql(u8, std.mem.span(raw_args[1]), internal_flag)) return;

    runLinuxSessionExec(init, raw_args[2..]);
}

/// Spawn a managed child. Production Linux builds route the child through the
/// private launcher above so it receives a fresh session and no controlling
/// terminal. Tests use a dedicated process group because the Zig test runner
/// does not execute ShellCore's main() launcher path.
pub fn spawnManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: std.process.SpawnOptions,
) !std.process.Child {
    if (builtin.os.tag != .linux) return std.process.spawn(io, options);

    if (builtin.is_test) {
        var test_options = options;
        test_options.pgid = 0;
        return std.process.spawn(io, test_options);
    }

    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);

    const wrapped_argv = try allocator.alloc([]const u8, options.argv.len + 2);
    defer allocator.free(wrapped_argv);
    wrapped_argv[0] = executable;
    wrapped_argv[1] = internal_flag;
    @memcpy(wrapped_argv[2..], options.argv);

    var wrapped_options = options;
    wrapped_options.argv = wrapped_argv;
    // Do not set pgid here: setsid() requires the launcher not to already be a
    // process-group leader. After setsid(), its PID becomes both SID and PGID.
    wrapped_options.pgid = null;
    return std.process.spawn(io, wrapped_options);
}

fn runLinuxSessionExec(init: std.process.Init, raw_argv: []const [*:0]const u8) noreturn {
    const linux = std.os.linux;

    if (raw_argv.len == 0) {
        std.debug.print("zshell internal launcher: missing program\n", .{});
        linux.exit(126);
    }

    if (linux.errno(linux.setsid()) != .SUCCESS) {
        std.debug.print("zshell internal launcher: setsid failed\n", .{});
        linux.exit(126);
    }

    const argv_storage = init.gpa.alloc(?[*:0]const u8, raw_argv.len + 1) catch {
        std.debug.print("zshell internal launcher: argv allocation failed\n", .{});
        linux.exit(126);
    };
    defer init.gpa.free(argv_storage);
    for (raw_argv, 0..) |arg, index| argv_storage[index] = arg;
    argv_storage[raw_argv.len] = null;

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_storage.ptr);
    const envp = init.minimal.environ.block.slice.ptr;
    const program_z = raw_argv[0];
    const program = std.mem.span(program_z);

    if (std.mem.findScalar(u8, program, '/') != null) {
        _ = linux.execve(program_z, argv, envp);
        std.debug.print("zshell internal launcher: unable to exec {s}\n", .{program});
        linux.exit(127);
    }

    const path = init.environ_map.get("PATH") orelse "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    var paths = std.mem.tokenizeScalar(u8, path, ':');
    while (paths.next()) |directory| {
        const full_len = directory.len + 1 + program.len;
        if (full_len + 1 > path_buffer.len) continue;

        @memcpy(path_buffer[0..directory.len], directory);
        path_buffer[directory.len] = '/';
        @memcpy(path_buffer[directory.len + 1 ..][0..program.len], program);
        path_buffer[full_len] = 0;

        const full_path = path_buffer[0..full_len :0];
        _ = linux.execve(full_path.ptr, argv, envp);
    }

    std.debug.print("zshell internal launcher: program not found: {s}\n", .{program});
    linux.exit(127);
}
