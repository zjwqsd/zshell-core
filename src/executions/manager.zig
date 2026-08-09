const std = @import("std");
const exec = @import("../tools/exec.zig");
const events = @import("../control/events.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const ExecutionId = u64;
pub const max_active: usize = 32;

pub const TrackedResult = struct {
    execution_id: ExecutionId,
    result: exec.Result,
};

pub const ListItem = struct {
    executionId: ExecutionId,
    command: []u8,
    cwd: ?[]u8,
    cancelRequested: bool,
    cancelSource: ?[]const u8,
};

pub const ListResult = struct {
    items: []ListItem,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.command);
            if (item.cwd) |cwd| allocator.free(cwd);
        }
        allocator.free(self.items);
    }
};

pub const LookupError = error{ExecutionNotFound};
pub const CapacityError = error{TooManyActiveExecutions};

const Execution = struct {
    id: ExecutionId,
    command: []const u8,
    cwd: ?[]const u8,
    mutex: std.Io.Mutex = .init,
    cancel_source: ?Source = null,
};

var registry_mutex: std.Io.Mutex = .init;
var active: [max_active]?*Execution = [_]?*Execution{null} ** max_active;
var next_id: ExecutionId = 1;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: exec.Input,
) !TrackedResult {
    var execution: Execution = .{
        .id = 0,
        .command = input.command,
        .cwd = input.cwd,
    };

    execution.id = try register(io, &execution);
    defer unregister(io, &execution);

    events.record(
        io,
        .agent,
        "exec.started",
        .execution,
        execution.id,
        input.command,
    );

    const result = exec.runControlled(
        allocator,
        io,
        input,
        .{
            .context = &execution,
            .requested = cancellationRequested,
        },
    ) catch |err| {
        events.record(
            io,
            .system,
            "exec.failed",
            .execution,
            execution.id,
            @errorName(err),
        );
        return err;
    };

    events.record(
        io,
        result.termination_source,
        "exec.completed",
        .execution,
        execution.id,
        result.termination,
    );

    return .{
        .execution_id = execution.id,
        .result = result,
    };
}

pub fn requestTerminate(
    io: std.Io,
    execution_id: ExecutionId,
    source: Source,
) LookupError!void {
    registry_mutex.lockUncancelable(io);
    const execution = findLocked(execution_id) orelse {
        registry_mutex.unlock(io);
        return error.ExecutionNotFound;
    };

    execution.mutex.lockUncancelable(io);
    registry_mutex.unlock(io);
    defer execution.mutex.unlock(io);

    if (execution.cancel_source == null) {
        execution.cancel_source = source;
        events.record(
            io,
            source,
            "exec.termination_requested",
            .execution,
            execution_id,
            "termination requested",
        );
    }
}

pub fn list(allocator: std.mem.Allocator, io: std.Io) !ListResult {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    var count: usize = 0;
    for (active) |slot| {
        if (slot != null) count += 1;
    }

    const items = try allocator.alloc(ListItem, count);
    errdefer allocator.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.command);
            if (item.cwd) |cwd| allocator.free(cwd);
        }
    }

    var index: usize = 0;
    for (active) |slot| {
        const execution = slot orelse continue;

        execution.mutex.lockUncancelable(io);
        const cancel_source = execution.cancel_source;
        execution.mutex.unlock(io);

        const command = try allocator.dupe(u8, execution.command);
        const cwd = if (execution.cwd) |value|
            allocator.dupe(u8, value) catch |err| {
                allocator.free(command);
                return err;
            }
        else
            null;

        items[index] = .{
            .executionId = execution.id,
            .command = command,
            .cwd = cwd,
            .cancelRequested = cancel_source != null,
            .cancelSource = if (cancel_source) |source| source.name() else null,
        };
        initialized += 1;
        index += 1;
    }

    return .{ .items = items };
}

fn register(io: std.Io, execution: *Execution) CapacityError!ExecutionId {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    for (&active) |*slot| {
        if (slot.* == null) {
            const id = next_id;
            next_id += 1;
            execution.id = id;
            slot.* = execution;
            return id;
        }
    }
    return error.TooManyActiveExecutions;
}

fn unregister(io: std.Io, execution: *Execution) void {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    execution.mutex.lockUncancelable(io);
    defer execution.mutex.unlock(io);

    for (&active) |*slot| {
        if (slot.* == execution) {
            slot.* = null;
            return;
        }
    }
}

fn findLocked(execution_id: ExecutionId) ?*Execution {
    for (active) |slot| {
        const execution = slot orelse continue;
        if (execution.id == execution_id) return execution;
    }
    return null;
}

fn cancellationRequested(context: *anyopaque, io: std.Io) ?Source {
    const execution: *Execution = @ptrCast(@alignCast(context));
    execution.mutex.lockUncancelable(io);
    defer execution.mutex.unlock(io);
    return execution.cancel_source;
}
