const std = @import("std");

pub const Owner = enum {
    agent,
    human,

    pub fn name(self: Owner) []const u8 {
        return @tagName(self);
    }
};

pub const Snapshot = struct {
    owner: Owner,
    generation: u64,

    pub fn canAgentExecute(self: Snapshot) bool {
        return self.owner == .agent;
    }
};

pub const Error = error{HumanControlActive};

var mutex: std.Io.Mutex = .init;
var owner: Owner = .agent;
var generation: u64 = 1;

pub fn snapshot(io: std.Io) Snapshot {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return .{ .owner = owner, .generation = generation };
}

pub fn requireAgent(io: std.Io) Error!void {
    if (snapshot(io).owner == .human) return error.HumanControlActive;
}

pub fn take(io: std.Io) Snapshot {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (owner != .human) {
        owner = .human;
        generation += 1;
    }
    return .{ .owner = owner, .generation = generation };
}

pub fn release(io: std.Io) Snapshot {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (owner != .agent) {
        owner = .agent;
        generation += 1;
    }
    return .{ .owner = owner, .generation = generation };
}

pub fn humanHasControl(io: std.Io) bool {
    return snapshot(io).owner == .human;
}

// Tests

test "control can be taken and released without side effects" {
    const io = std.testing.io;
    _ = release(io);

    const initial = snapshot(io);
    try std.testing.expectEqual(Owner.agent, initial.owner);

    const taken = take(io);
    try std.testing.expectEqual(Owner.human, taken.owner);
    try std.testing.expectError(error.HumanControlActive, requireAgent(io));

    const released = release(io);
    try std.testing.expectEqual(Owner.agent, released.owner);
    try requireAgent(io);
}
