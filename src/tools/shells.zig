const std = @import("std");
const manager = @import("../shells/manager.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const ShellId = manager.ShellId;
pub const Status = manager.Status;
pub const StartInput = manager.StartInput;
pub const StartResult = manager.StartResult;
pub const WriteResult = manager.WriteResult;
pub const ReadResult = manager.ReadResult;
pub const KillResult = manager.KillResult;
pub const ListItem = manager.ListItem;
pub const ListResult = manager.ListResult;
pub const backend_name = manager.backend_name;

var global_manager: ?manager.Manager = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    std.debug.assert(global_manager == null);
    global_manager = manager.Manager.init(allocator, io);
}

pub fn deinit() void {
    if (global_manager) |*shells| {
        shells.deinit();
        global_manager = null;
    }
}

pub fn start(input: StartInput) !StartResult {
    return getManager().start(input);
}

pub fn write(
    shell_id: ShellId,
    input: []const u8,
    enter: bool,
) !WriteResult {
    return getManager().write(shell_id, input, enter);
}

pub fn read(
    allocator: std.mem.Allocator,
    shell_id: ShellId,
) !ReadResult {
    return getManager().read(allocator, shell_id);
}

pub fn kill(shell_id: ShellId) manager.LookupError!KillResult {
    return killBy(shell_id, .agent);
}

pub fn killBy(shell_id: ShellId, source: Source) manager.LookupError!KillResult {
    return getManager().kill(shell_id, source);
}

pub fn list(allocator: std.mem.Allocator) !ListResult {
    return getManager().list(allocator);
}

fn getManager() *manager.Manager {
    if (global_manager) |*shells| return shells;
    @panic("shells subsystem is not initialized");
}
