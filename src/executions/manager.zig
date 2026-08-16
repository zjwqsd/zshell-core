const std = @import("std");
const exec = @import("../tools/exec.zig");
const events = @import("../control/events.zig");
pub const Source = @import("../runtime/source.zig").Source;

pub const ExecutionId = u64;
pub const max_active: usize = 32;
pub const history_capacity: usize = 128;
pub const history_command_capacity: usize = 512;
pub const history_cwd_capacity: usize = 256;
pub const history_termination_capacity: usize = 64;

pub const HistoryStatus = enum {
    completed,
    failed,

    pub fn name(self: HistoryStatus) []const u8 {
        return @tagName(self);
    }
};

pub const HistoryItem = struct {
    executionId: ExecutionId,
    command: []u8,
    cwd: ?[]u8,
    status: HistoryStatus,
    exitCode: ?u8,
    termination: []u8,
    terminationSource: Source,
};

pub const HistoryResult = struct {
    items: []HistoryItem,

    pub fn deinit(self: HistoryResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.command);
            if (item.cwd) |cwd| allocator.free(cwd);
            allocator.free(item.termination);
        }
        allocator.free(self.items);
    }
};

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

const HistoryEntry = struct {
    execution_id: ExecutionId = 0,
    command: [history_command_capacity]u8 = [_]u8{0} ** history_command_capacity,
    command_len: usize = 0,
    cwd: [history_cwd_capacity]u8 = [_]u8{0} ** history_cwd_capacity,
    cwd_len: usize = 0,
    has_cwd: bool = false,
    status: HistoryStatus = .completed,
    exit_code: ?u8 = null,
    termination: [history_termination_capacity]u8 = [_]u8{0} ** history_termination_capacity,
    termination_len: usize = 0,
    termination_source: Source = .system,
};

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
var history: [history_capacity]HistoryEntry = [_]HistoryEntry{.{}} ** history_capacity;
var history_count: usize = 0;
var history_next: usize = 0;

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
        recordHistory(io, execution.id, input.command, input.cwd, .failed, null, @errorName(err), .system);
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

    recordHistory(
        io,
        execution.id,
        input.command,
        input.cwd,
        .completed,
        result.exit_code,
        result.termination,
        result.termination_source,
    );

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

pub fn historyRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    max_items: usize,
) !HistoryResult {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    const item_count = @min(history_count, max_items);
    const items = try allocator.alloc(HistoryItem, item_count);
    errdefer allocator.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.command);
            if (item.cwd) |cwd| allocator.free(cwd);
            allocator.free(item.termination);
        }
    }

    for (0..item_count) |offset| {
        const logical = history_count - item_count + offset;
        const oldest = if (history_count < history_capacity) 0 else history_next;
        const index = (oldest + logical) % history_capacity;
        const entry = &history[index];
        const command = try allocator.dupe(u8, entry.command[0..entry.command_len]);
        const cwd = if (entry.has_cwd)
            allocator.dupe(u8, entry.cwd[0..entry.cwd_len]) catch |err| {
                allocator.free(command);
                return err;
            }
        else
            null;
        const termination = allocator.dupe(u8, entry.termination[0..entry.termination_len]) catch |err| {
            allocator.free(command);
            if (cwd) |value| allocator.free(value);
            return err;
        };
        items[offset] = .{
            .executionId = entry.execution_id,
            .command = command,
            .cwd = cwd,
            .status = entry.status,
            .exitCode = entry.exit_code,
            .termination = termination,
            .terminationSource = entry.termination_source,
        };
        initialized += 1;
    }
    return .{ .items = items };
}

fn recordHistory(
    io: std.Io,
    execution_id: ExecutionId,
    command: []const u8,
    cwd: ?[]const u8,
    status: HistoryStatus,
    exit_code: ?u8,
    termination: []const u8,
    termination_source: Source,
) void {
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    var entry = &history[history_next];
    entry.* = .{};
    entry.execution_id = execution_id;
    entry.command_len = @min(command.len, entry.command.len);
    @memcpy(entry.command[0..entry.command_len], command[0..entry.command_len]);
    if (cwd) |value| {
        entry.has_cwd = true;
        entry.cwd_len = @min(value.len, entry.cwd.len);
        @memcpy(entry.cwd[0..entry.cwd_len], value[0..entry.cwd_len]);
    }
    entry.status = status;
    entry.exit_code = exit_code;
    entry.termination_len = @min(termination.len, entry.termination.len);
    @memcpy(entry.termination[0..entry.termination_len], termination[0..entry.termination_len]);
    entry.termination_source = termination_source;

    history_next = (history_next + 1) % history_capacity;
    if (history_count < history_capacity) history_count += 1;
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
