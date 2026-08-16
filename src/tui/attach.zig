const std = @import("std");
const vaxis = @import("vaxis");
const shells = @import("../tools/shells.zig");
const events = @import("../control/events.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    shell_id: u64,
) !void {
    if (!isRunning(allocator, shell_id)) return error.ShellNotRunning;

    var tty_buffer: [4096]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &tty_buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, allocator, environ_map, .{});
    defer vx.deinit(allocator, writer);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try vx.queryTerminal(writer, .fromSeconds(1));
    try writer.writeAll("\x1b[2J\x1b[H");
    try writer.flush();

    const initial_ws = try tty.getWinsize();
    try resizeShell(shell_id, initial_ws);

    var stdout_after: ?u64 = null;
    var stderr_after: ?u64 = null;
    events.record(io, .human, "shell.attach_started", .shell, shell_id, "local terminal attached");
    defer events.record(io, .human, "shell.attach_detached", .shell, shell_id, "local terminal detached");

    while (true) {
        const output = try shells.read(allocator, shell_id, stdout_after, stderr_after);
        defer output.deinit(allocator);

        if (output.stdout.len != 0) try writer.writeAll(output.stdout);
        if (output.stderr.len != 0) try writer.writeAll(output.stderr);
        if (output.stdout.len != 0 or output.stderr.len != 0) try writer.flush();
        stdout_after = output.stdout_next_offset;
        stderr_after = output.stderr_next_offset;
        if (output.status != .running) return;

        while (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.matches(']', .{ .ctrl = true })) return;
                    var encoded_buffer: [64]u8 = undefined;
                    var encoded: std.Io.Writer = .fixed(&encoded_buffer);
                    try encodeKey(&encoded, key);
                    const bytes = encoded.buffered();
                    if (bytes.len != 0) _ = try shells.writeAttached(shell_id, bytes);
                },
                .winsize => |ws| {
                    try vx.resize(allocator, writer, ws);
                    try resizeShell(shell_id, ws);
                },
            }
        }

        try io.sleep(.fromMilliseconds(12), .awake);
    }
}

fn isRunning(allocator: std.mem.Allocator, shell_id: u64) bool {
    const output = shells.read(allocator, shell_id, 0, 0) catch return false;
    defer output.deinit(allocator);
    return output.status == .running;
}

fn resizeShell(shell_id: u64, ws: vaxis.Winsize) !void {
    if (ws.cols == 0 or ws.rows == 0) return;
    _ = try shells.resize(shell_id, ws.cols, ws.rows);
}

fn encodeKey(writer: *std.Io.Writer, key: vaxis.Key) !void {
    if (key.text) |text| {
        try writer.writeAll(text);
        return;
    }

    const shift: u8 = 0b00000001;
    const alt: u8 = 0b00000010;
    const ctrl: u8 = 0b00000100;
    const mods: u8 = @bitCast(key.mods);
    const effective = mods & (shift | alt | ctrl);

    if (effective == 0 and key.codepoint <= 0x7f) {
        try writer.writeByte(@truncate(key.codepoint));
        return;
    }

    if (effective == ctrl and key.codepoint >= '@' and key.codepoint <= '_') {
        try writer.writeByte(@as(u8, @truncate(key.codepoint)) & 0x1f);
        return;
    }
    if (effective == ctrl and key.codepoint >= 'a' and key.codepoint <= 'z') {
        try writer.writeByte(@as(u8, @truncate(key.codepoint)) - 0x60);
        return;
    }
    if (effective == alt and key.codepoint >= ' ' and key.codepoint < 0x7f) {
        try writer.writeByte(0x1b);
        try writer.writeByte(@truncate(key.codepoint));
        return;
    }
    if (effective == (ctrl | alt) and key.codepoint >= 'a' and key.codepoint <= 'z') {
        try writer.writeByte(0x1b);
        try writer.writeByte(@as(u8, @truncate(key.codepoint)) - 0x60);
        return;
    }

    const definition: Definition = switch (key.codepoint) {
        vaxis.Key.escape => .{ .number = 27, .suffix = 'u' },
        vaxis.Key.enter, vaxis.Key.kp_enter => .{ .number = 13, .suffix = 'u' },
        vaxis.Key.tab => .{ .number = 9, .suffix = 'u' },
        vaxis.Key.backspace => .{ .number = 127, .suffix = 'u' },
        vaxis.Key.insert, vaxis.Key.kp_insert => .{ .number = 2, .suffix = '~' },
        vaxis.Key.delete, vaxis.Key.kp_delete => .{ .number = 3, .suffix = '~' },
        vaxis.Key.left, vaxis.Key.kp_left => .{ .number = 1, .suffix = 'D' },
        vaxis.Key.right, vaxis.Key.kp_right => .{ .number = 1, .suffix = 'C' },
        vaxis.Key.up, vaxis.Key.kp_up => .{ .number = 1, .suffix = 'A' },
        vaxis.Key.down, vaxis.Key.kp_down => .{ .number = 1, .suffix = 'B' },
        vaxis.Key.page_up, vaxis.Key.kp_page_up => .{ .number = 5, .suffix = '~' },
        vaxis.Key.page_down, vaxis.Key.kp_page_down => .{ .number = 6, .suffix = '~' },
        vaxis.Key.home, vaxis.Key.kp_home => .{ .number = 1, .suffix = 'H' },
        vaxis.Key.end, vaxis.Key.kp_end => .{ .number = 1, .suffix = 'F' },
        vaxis.Key.f1 => .{ .number = 1, .suffix = 'P', .ss3 = true },
        vaxis.Key.f2 => .{ .number = 1, .suffix = 'Q', .ss3 = true },
        vaxis.Key.f3 => .{ .number = 1, .suffix = 'R', .ss3 = true },
        vaxis.Key.f4 => .{ .number = 1, .suffix = 'S', .ss3 = true },
        vaxis.Key.f5 => .{ .number = 15, .suffix = '~' },
        vaxis.Key.f6 => .{ .number = 17, .suffix = '~' },
        vaxis.Key.f7 => .{ .number = 18, .suffix = '~' },
        vaxis.Key.f8 => .{ .number = 19, .suffix = '~' },
        vaxis.Key.f9 => .{ .number = 20, .suffix = '~' },
        vaxis.Key.f10 => .{ .number = 21, .suffix = '~' },
        vaxis.Key.f11 => .{ .number = 23, .suffix = '~' },
        vaxis.Key.f12 => .{ .number = 24, .suffix = '~' },
        else => return,
    };

    if (effective == 0) {
        if (definition.ss3) {
            try writer.print("\x1bO{c}", .{definition.suffix});
        } else if (definition.number == 1) {
            try writer.print("\x1b[{c}", .{definition.suffix});
        } else {
            try writer.print("\x1b[{d}{c}", .{ definition.number, definition.suffix });
        }
    } else {
        try writer.print("\x1b[{d};{d}{c}", .{ definition.number, effective + 1, definition.suffix });
    }
}

const Definition = struct {
    number: u21,
    suffix: u8,
    ss3: bool = false,
};
