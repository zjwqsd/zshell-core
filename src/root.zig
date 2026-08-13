pub const version = @import("version.zig");

pub const device = struct {
    pub const client = @import("device/client.zig");
    pub const transfer = @import("device/transfer.zig");
};

pub const protocol = struct {
    pub const browser = @import("protocol/browser.zig");
    pub const dispatcher = @import("protocol/dispatcher.zig");
    pub const files = @import("protocol/files.zig");
    pub const output = @import("protocol/output.zig");
};

pub const tools = struct {
    pub const browser = @import("tools/browser.zig");
    pub const environment = @import("tools/environment.zig");
    pub const exec = @import("tools/exec.zig");
    pub const filesystem = @import("tools/filesystem.zig");
    pub const jobs = @import("tools/jobs.zig");
    pub const shells = @import("tools/shells.zig");
};

pub const jobs = struct {
    pub const manager = @import("jobs/manager.zig");
};

pub const shells = struct {
    pub const manager = @import("shells/manager.zig");
};

pub const executions = struct {
    pub const manager = @import("executions/manager.zig");
};

pub const control = struct {
    pub const state = @import("control/state.zig");
    pub const events = @import("control/events.zig");
    pub const server = @import("control/server.zig");
};

pub const runtime = struct {
    pub const source = @import("runtime/source.zig");
    pub const ports = @import("runtime/ports.zig");
    pub const secrets = @import("runtime/secrets.zig");
    pub const terminal = @import("runtime/terminal.zig");
};
