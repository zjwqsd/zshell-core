const std = @import("std");
const manager = @import("../jobs/manager.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const JobId = manager.JobId;
pub const Status = manager.Status;
pub const StartInput = manager.StartInput;
pub const StartResult = manager.StartResult;
pub const StatusResult = manager.StatusResult;
pub const LogsResult = manager.LogsResult;
pub const ListItem = manager.ListItem;
pub const ListResult = manager.ListResult;

var global_manager: ?manager.Manager = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: anytype) !void {
    std.debug.assert(global_manager == null);
    global_manager = try manager.Manager.init(allocator, io, environ_map);
}

pub fn deinit() void {
    if (global_manager) |*jobs| {
        jobs.deinit();
        global_manager = null;
    }
}

pub fn start(input: StartInput) !StartResult {
    return getManager().start(input);
}

pub fn status(job_id: JobId) manager.Error!StatusResult {
    return getManager().status(job_id);
}

pub fn logs(
    allocator: std.mem.Allocator,
    job_id: JobId,
    stdout_after: ?u64,
    stderr_after: ?u64,
) !LogsResult {
    return getManager().logs(allocator, job_id, stdout_after, stderr_after);
}

pub fn stop(job_id: JobId) manager.Error!StatusResult {
    return stopBy(job_id, .agent);
}

pub fn stopBy(job_id: JobId, source: Source) manager.Error!StatusResult {
    return getManager().stop(job_id, source);
}

pub fn list(allocator: std.mem.Allocator) !ListResult {
    return getManager().list(allocator);
}

fn getManager() *manager.Manager {
    if (global_manager) |*jobs| return jobs;
    @panic("jobs subsystem is not initialized");
}
