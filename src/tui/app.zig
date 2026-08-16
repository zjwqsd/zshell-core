const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const control = @import("../control/state.zig");
const events = @import("../control/events.zig");
const executions = @import("../executions/manager.zig");
const jobs = @import("../tools/jobs.zig");
const shells = @import("../tools/shells.zig");

pub const Action = union(enum) {
    quit,
    attach: u64,
};

const ResourceKind = enum {
    exec_active,
    exec_history,
    job,
    shell,
};

const ResourceRef = struct {
    kind: ResourceKind,
    id: u64,
};

const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    selected: usize = 0,
    selected_ref: ?ResourceRef = null,
    visible_count: usize = 0,
    detail_open: bool = false,
    filtering: bool = false,
    filter: [128]u8 = [_]u8{0} ** 128,
    filter_len: usize = 0,
    attach_request: ?u64 = null,
    status: [160]u8 = [_]u8{0} ** 160,
    status_len: usize = 0,

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.tick(250, self.widget());
                try ctx.setTitle("zshell-core");
                ctx.redraw = true;
            },
            .tick => {
                try ctx.tick(250, self.widget());
                ctx.redraw = true;
            },
            .key_press => |key| try self.handleKey(ctx, key),
            else => {},
        }
    }

    fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (self.filtering) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.filtering = false;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                self.filtering = false;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.backspace, .{})) {
                if (self.filter_len > 0) self.filter_len -= 1;
                self.selected = 0;
                return ctx.consumeAndRedraw();
            }
            if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= 0x20 and key.codepoint <= 0x7e and self.filter_len < self.filter.len) {
                self.filter[self.filter_len] = @intCast(key.codepoint);
                self.filter_len += 1;
                self.selected = 0;
                return ctx.consumeAndRedraw();
            }
            return;
        }

        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.detail_open) {
                self.detail_open = false;
                return ctx.consumeAndRedraw();
            }
            if (self.filter_len != 0) {
                self.filter_len = 0;
                self.selected = 0;
                return ctx.consumeAndRedraw();
            }
        }
        if (key.matches('/', .{})) {
            self.filtering = true;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.visible_count > 0 and self.selected + 1 < self.visible_count) self.selected += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.selected > 0) self.selected -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.selected_ref != null) self.detail_open = !self.detail_open;
            return ctx.consumeAndRedraw();
        }
        if (key.matches('t', .{})) {
            const before = control.snapshot(self.io);
            if (before.owner == .agent) {
                _ = control.take(self.io);
                events.record(self.io, .human, "control.taken", .control, null, "Human control enabled from TUI");
                self.setStatus("Human control enabled");
            } else {
                _ = control.release(self.io);
                events.record(self.io, .human, "control.released", .control, null, "Agent control restored from TUI");
                self.setStatus("Agent control restored");
            }
            return ctx.consumeAndRedraw();
        }
        if (key.matches('x', .{})) {
            try self.stopSelected();
            return ctx.consumeAndRedraw();
        }
        if (key.matches('a', .{})) {
            const owner = control.snapshot(self.io).owner;
            if (owner != .human) {
                self.setStatus("Press t to take Human Control before attach");
                return ctx.consumeAndRedraw();
            }
            if (self.selected_ref) |selected| {
                if (selected.kind == .shell) {
                    self.attach_request = selected.id;
                    events.record(self.io, .human, "shell.attach_requested", .shell, selected.id, "local TUI attach");
                    ctx.quit = true;
                    return;
                }
            }
            self.setStatus("Attach is available for a Shell row");
            return ctx.consumeAndRedraw();
        }
    }

    fn stopSelected(self: *Model) !void {
        if (control.snapshot(self.io).owner != .human) {
            self.setStatus("Press t to take Human Control before stopping work");
            return;
        }
        const selected = self.selected_ref orelse {
            self.setStatus("Nothing selected");
            return;
        };
        switch (selected.kind) {
            .exec_active => {
                executions.requestTerminate(self.io, selected.id, .human) catch |err| {
                    self.setStatus(@errorName(err));
                    return;
                };
                self.setStatus("Exec termination requested");
            },
            .job => {
                _ = jobs.stopBy(selected.id, .human) catch |err| {
                    self.setStatus(@errorName(err));
                    return;
                };
                self.setStatus("Job stopped");
            },
            .shell => {
                _ = shells.killBy(selected.id, .human) catch |err| {
                    self.setStatus(@errorName(err));
                    return;
                };
                self.setStatus("Shell killed");
            },
            .exec_history => self.setStatus("Completed Exec history is read-only"),
        }
    }

    fn setStatus(self: *Model, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
    }

    fn filterText(self: *const Model) []const u8 {
        return self.filter[0..self.filter_len];
    }

    fn matchesFilter(self: *const Model, text: []const u8) bool {
        const needle = self.filterText();
        if (needle.len == 0) return true;
        return std.mem.indexOf(u8, text, needle) != null;
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.draw(ctx) catch |err| self.drawFailure(ctx, @errorName(err));
    }

    fn drawFailure(self: *Model, ctx: vxfw.DrawContext, message: []const u8) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width == 0 or size.height == 0) return surface;
        putText(ctx, surface, 0, 1, "zshell-core", .{ .bold = true }, size.width -| 2);
        if (size.height > 2) putText(ctx, surface, 2, 1, "TUI refresh error", .{ .bold = true, .fg = .{ .index = 1 } }, size.width -| 2);
        if (size.height > 3) putText(ctx, surface, 3, 1, message, .{}, size.width -| 2);
        return surface;
    }

    fn draw(self: *Model, ctx: vxfw.DrawContext) !vxfw.Surface {
        const size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width == 0 or size.height == 0) return surface;

        const owner = control.snapshot(self.io).owner;
        const owner_style: vaxis.Cell.Style = if (owner == .human)
            .{ .bold = true, .fg = .{ .index = 3 } }
        else
            .{ .bold = true, .fg = .{ .index = 2 } };
        putText(ctx, surface, 0, 1, "zshell-core", .{ .bold = true, .fg = .{ .index = 6 } }, size.width -| 2);
        const owner_text = try std.fmt.allocPrint(ctx.arena, "CONTROL: {s}", .{owner.name()});
        const owner_col: u16 = if (size.width > owner_text.len + 2) @intCast(size.width - owner_text.len - 1) else 1;
        putText(ctx, surface, 0, owner_col, owner_text, owner_style, size.width -| owner_col);
        putText(ctx, surface, 1, 1, "j/k move  Enter detail  t control  x stop  a attach  / filter  q quit", .{ .dim = true }, size.width -| 2);
        drawRule(surface, 2, size.width);

        if (size.height <= 5) return surface;
        const footer_row = size.height - 1;
        drawRule(surface, footer_row - 1, size.width);
        if (self.filtering) {
            const prompt = try std.fmt.allocPrint(ctx.arena, "/{s}_", .{self.filterText()});
            putText(ctx, surface, footer_row, 1, prompt, .{ .bold = true }, size.width -| 2);
        } else if (self.filter_len != 0) {
            const prompt = try std.fmt.allocPrint(ctx.arena, "filter: {s}", .{self.filterText()});
            putText(ctx, surface, footer_row, 1, prompt, .{ .dim = true }, size.width -| 2);
        } else if (self.status_len != 0) {
            putText(ctx, surface, footer_row, 1, self.status[0..self.status_len], .{ .fg = .{ .index = 3 } }, size.width -| 2);
        } else if (owner == .human) {
            putText(ctx, surface, footer_row, 1, "Agent mutations pause while Human Control is active", .{ .dim = true }, size.width -| 2);
        } else {
            putText(ctx, surface, footer_row, 1, "Agent control active", .{ .dim = true }, size.width -| 2);
        }

        const content_top: u16 = 3;
        const content_bottom: u16 = footer_row - 1;
        if (self.detail_open) {
            try self.drawDetail(ctx, surface, content_top, 1, content_bottom - content_top, size.width -| 2);
            return surface;
        }

        const wide = size.width >= 100;
        const left_width: u16 = if (wide) @intCast((@as(u32, size.width) * 58) / 100) else size.width;
        const right_col: u16 = if (wide) left_width + 1 else 0;
        if (wide) drawVerticalRule(surface, content_top, content_bottom, left_width);

        try self.drawDashboard(ctx, surface, content_top, 1, content_bottom - content_top, left_width -| 2);
        if (wide) {
            const right_width = size.width -| right_col -| 1;
            const total_height = content_bottom - content_top;
            const detail_height = if (total_height > 12) total_height / 2 else total_height;
            try self.drawDetail(ctx, surface, content_top, right_col, detail_height, right_width);
            if (detail_height < total_height) {
                try self.drawEvents(ctx, surface, content_top + detail_height + 1, right_col, total_height - detail_height - 1, right_width);
            }
        } else if (content_bottom - content_top > 16) {
            try self.drawEvents(ctx, surface, content_bottom - 6, 1, 6, size.width -| 2);
        }
        return surface;
    }

    fn drawDashboard(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, top: u16, col: u16, height: u16, width: u16) !void {
        var row = top;
        var index: usize = 0;
        var selected_ref: ?ResourceRef = null;
        var last_ref: ?ResourceRef = null;

        const active = try executions.list(ctx.arena, self.io);
        const history = try executions.historyRecent(ctx.arena, self.io, 16);
        const job_list = try jobs.list(ctx.arena);
        const shell_list = try shells.list(ctx.arena);
        sortJobs(job_list.items);
        sortShells(shell_list.items);

        if (row < top + height) {
            putText(ctx, surface, row, col, "EXEC", .{ .bold = true, .fg = .{ .index = 6 } }, width);
            row += 1;
        }
        for (active.items) |item| {
            if (!self.matchesFilter(item.command)) continue;
            const ref: ResourceRef = .{ .kind = .exec_active, .id = item.executionId };
            const text = try std.fmt.allocPrint(ctx.arena, "#{d:<4} running   {s}", .{ item.executionId, item.command });
            if (row < top + height) drawResource(ctx, surface, row, col, width, text, index == self.selected, .running);
            if (index == self.selected) selected_ref = ref;
            last_ref = ref;
            index += 1;
            row +|= 1;
        }
        var h = history.items.len;
        while (h > 0) {
            h -= 1;
            const item = history.items[h];
            if (!self.matchesFilter(item.command)) continue;
            const ref: ResourceRef = .{ .kind = .exec_history, .id = item.executionId };
            const text = try std.fmt.allocPrint(ctx.arena, "#{d:<4} {s:<9} {s}", .{ item.executionId, item.status.name(), item.command });
            const state: VisualState = if (item.status == .failed or (item.exitCode != null and item.exitCode.? != 0)) .failed else .done;
            if (row < top + height) drawResource(ctx, surface, row, col, width, text, index == self.selected, state);
            if (index == self.selected) selected_ref = ref;
            last_ref = ref;
            index += 1;
            row +|= 1;
        }

        if (row < top + height) {
            putText(ctx, surface, row, col, "JOB", .{ .bold = true, .fg = .{ .index = 6 } }, width);
            row += 1;
        }
        for (job_list.items) |item| {
            if (!self.matchesFilter(item.program)) continue;
            const ref: ResourceRef = .{ .kind = .job, .id = item.job_id };
            const text = try std.fmt.allocPrint(ctx.arena, "#{d:<4} {s:<9} {s}", .{ item.job_id, item.status.name(), item.program });
            const state: VisualState = switch (item.status) {
                .running => .running,
                .failed => .failed,
                else => .done,
            };
            if (row < top + height) drawResource(ctx, surface, row, col, width, text, index == self.selected, state);
            if (index == self.selected) selected_ref = ref;
            last_ref = ref;
            index += 1;
            row +|= 1;
        }

        if (row < top + height) {
            putText(ctx, surface, row, col, "SHELL", .{ .bold = true, .fg = .{ .index = 6 } }, width);
            row += 1;
        }
        for (shell_list.items) |item| {
            if (!self.matchesFilter(item.shell)) continue;
            const ref: ResourceRef = .{ .kind = .shell, .id = item.shell_id };
            const text = try std.fmt.allocPrint(ctx.arena, "#{d:<4} {s:<9} {s}  {d}x{d}", .{ item.shell_id, item.status.name(), item.shell, item.cols, item.rows });
            const state: VisualState = switch (item.status) {
                .running => .running,
                .failed => .failed,
                else => .done,
            };
            if (row < top + height) drawResource(ctx, surface, row, col, width, text, index == self.selected, state);
            if (index == self.selected) selected_ref = ref;
            last_ref = ref;
            index += 1;
            row +|= 1;
        }

        self.visible_count = index;
        if (index == 0) {
            self.selected = 0;
            self.selected_ref = null;
        } else if (self.selected >= index) {
            self.selected = index - 1;
            self.selected_ref = last_ref;
        } else {
            self.selected_ref = selected_ref;
        }
    }

    fn drawDetail(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, top: u16, col: u16, height: u16, width: u16) !void {
        if (height == 0 or width == 0) return;
        putText(ctx, surface, top, col, "DETAIL", .{ .bold = true, .fg = .{ .index = 6 } }, width);
        const selected = self.selected_ref orelse {
            if (height > 1) putText(ctx, surface, top + 1, col, "No resource selected", .{ .dim = true }, width);
            return;
        };
        var row = top + 1;
        const end = top + height;
        const header = try std.fmt.allocPrint(ctx.arena, "{s} #{d}", .{ @tagName(selected.kind), selected.id });
        putText(ctx, surface, row, col, header, .{ .bold = true }, width);
        row += 1;

        switch (selected.kind) {
            .exec_active => {
                const active = try executions.list(ctx.arena, self.io);
                for (active.items) |item| if (item.executionId == selected.id) {
                    row = drawField(ctx, surface, row, col, end, width, "command", item.command);
                    row = drawField(ctx, surface, row, col, end, width, "cwd", item.cwd orelse "-");
                    const cancel = if (item.cancelRequested) item.cancelSource orelse "requested" else "no";
                    _ = drawField(ctx, surface, row, col, end, width, "cancel", cancel);
                    break;
                };
            },
            .exec_history => {
                const history = try executions.historyRecent(ctx.arena, self.io, executions.history_capacity);
                for (history.items) |item| if (item.executionId == selected.id) {
                    row = drawField(ctx, surface, row, col, end, width, "command", item.command);
                    row = drawField(ctx, surface, row, col, end, width, "cwd", item.cwd orelse "-");
                    row = drawField(ctx, surface, row, col, end, width, "termination", item.termination);
                    _ = drawField(ctx, surface, row, col, end, width, "source", item.terminationSource.name());
                    break;
                };
            },
            .job => {
                const list = try jobs.list(ctx.arena);
                sortJobs(list.items);
                for (list.items) |item| if (item.job_id == selected.id) {
                    row = drawField(ctx, surface, row, col, end, width, "program", item.program);
                    row = drawField(ctx, surface, row, col, end, width, "cwd", item.cwd orelse "-");
                    if (row < end) {
                        putText(ctx, surface, row, col, "recent output", .{ .bold = true }, width);
                        row += 1;
                    }
                    const status = try jobs.status(selected.id);
                    const out_after: ?u64 = if (status.stdout_bytes > 8192) status.stdout_bytes - 8192 else null;
                    const err_after: ?u64 = if (status.stderr_bytes > 4096) status.stderr_bytes - 4096 else null;
                    const logs = try jobs.logs(ctx.arena, selected.id, out_after, err_after);
                    row = drawTail(ctx, surface, row, col, end, width, logs.stdout);
                    _ = drawTail(ctx, surface, row, col, end, width, logs.stderr);
                    break;
                };
            },
            .shell => {
                const list = try shells.list(ctx.arena);
                sortShells(list.items);
                for (list.items) |item| if (item.shell_id == selected.id) {
                    row = drawField(ctx, surface, row, col, end, width, "shell", item.shell);
                    row = drawField(ctx, surface, row, col, end, width, "cwd", item.initial_cwd orelse "-");
                    if (row < end) {
                        putText(ctx, surface, row, col, "recent output", .{ .bold = true }, width);
                        row += 1;
                    }
                    const offsets = try shells.outputOffsets(selected.id);
                    const out_after: ?u64 = if (offsets.stdout_bytes > 8192) offsets.stdout_bytes - 8192 else null;
                    const err_after: ?u64 = if (offsets.stderr_bytes > 4096) offsets.stderr_bytes - 4096 else null;
                    const output = try shells.read(ctx.arena, selected.id, out_after, err_after);
                    row = drawTail(ctx, surface, row, col, end, width, output.stdout);
                    _ = drawTail(ctx, surface, row, col, end, width, output.stderr);
                    break;
                };
            },
        }
    }

    fn drawEvents(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, top: u16, col: u16, height: u16, width: u16) !void {
        if (height == 0) return;
        putText(ctx, surface, top, col, "EVENTS", .{ .bold = true, .fg = .{ .index = 6 } }, width);
        if (height == 1) return;
        const snapshot = try events.snapshotRecent(ctx.arena, self.io, height - 1);
        var row = top + 1;
        for (snapshot.items) |item| {
            if (row >= top + height) break;
            const line = try std.fmt.allocPrint(ctx.arena, "{d:>4} [{s}] {s}: {s}", .{ item.seq, item.source, item.kind, item.message });
            putText(ctx, surface, row, col, line, .{ .dim = item.source.len != 5 or !std.mem.eql(u8, item.source, "human") }, width);
            row += 1;
        }
    }
};

const VisualState = enum { running, done, failed };

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) !Action {
    var buffer: [4096]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, environ_map, &buffer);
    defer app.deinit();

    var model: Model = .{ .allocator = allocator, .io = io };
    try app.run(model.widget(), .{ .framerate = 30 });
    if (model.attach_request) |shell_id| return .{ .attach = shell_id };
    return .quit;
}

fn drawResource(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: u16, col: u16, width: u16, text: []const u8, selected: bool, state: VisualState) void {
    const style: vaxis.Cell.Style = if (selected)
        .{ .reverse = true, .bold = true }
    else switch (state) {
        .running => .{ .fg = .{ .index = 2 } },
        .done => .{ .dim = true },
        .failed => .{ .fg = .{ .index = 1 }, .bold = true },
    };
    putText(ctx, surface, row, col, text, style, width);
    if (selected) fillStyle(surface, row, col, width, style);
}

fn fillStyle(surface: vxfw.Surface, row: u16, col: u16, width: u16, style: vaxis.Cell.Style) void {
    var x: u16 = 0;
    while (x < width and col + x < surface.size.width) : (x += 1) {
        const current = surface.readCell(col + x, row);
        var cell = current;
        cell.style = style;
        surface.writeCell(col + x, row, cell);
    }
}

fn putText(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: u16, col_start: u16, text: []const u8, style: vaxis.Cell.Style, max_width: u16) void {
    if (row >= surface.size.height or col_start >= surface.size.width or max_width == 0) return;
    var col = col_start;
    const limit = @min(surface.size.width, col_start +| max_width);
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme_info| {
        const grapheme = grapheme_info.bytes(text);
        if (std.mem.eql(u8, grapheme, "\n") or std.mem.eql(u8, grapheme, "\r")) break;
        const grapheme_width: u8 = @intCast(@max(1, ctx.stringWidth(grapheme)));
        if (col +| grapheme_width > limit) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = grapheme_width },
            .style = style,
        });
        col +|= grapheme_width;
    }
}

fn drawRule(surface: vxfw.Surface, row: u16, width: u16) void {
    if (row >= surface.size.height) return;
    for (0..@min(width, surface.size.width)) |x| surface.writeCell(@intCast(x), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .dim = true } });
}

fn drawVerticalRule(surface: vxfw.Surface, top: u16, bottom: u16, col: u16) void {
    if (col >= surface.size.width) return;
    var row = top;
    while (row < bottom and row < surface.size.height) : (row += 1) surface.writeCell(col, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = .{ .dim = true } });
}

fn drawField(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: u16, col: u16, end: u16, width: u16, name: []const u8, value: []const u8) u16 {
    if (row >= end) return row;
    const label = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ name, value }) catch return row;
    putText(ctx, surface, row, col, label, .{}, width);
    return row + 1;
}

fn drawTail(ctx: vxfw.DrawContext, surface: vxfw.Surface, row_start: u16, col: u16, end: u16, width: u16, text: []const u8) u16 {
    if (row_start >= end or text.len == 0) return row_start;

    // PTY output contains ANSI/OSC control sequences and arbitrary UTF-8.  The
    // surface keeps grapheme slices alive until the frame is rendered, so the
    // sanitized text must live in the frame arena rather than a stack buffer.
    const clean = sanitizeTerminalText(ctx.arena, text) catch return row_start;
    if (clean.len == 0) return row_start;

    const available: usize = end - row_start;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, clean, '\n');
    while (it.next() != null) count += 1;
    const skip = count -| available;
    it = std.mem.splitScalar(u8, clean, '\n');
    var index: usize = 0;
    var row = row_start;
    while (it.next()) |line| : (index += 1) {
        if (index < skip) continue;
        if (row >= end) break;
        putText(ctx, surface, row, col, line, .{ .dim = true }, width);
        row += 1;
    }
    return row;
}

const TerminalSanitizeState = enum {
    text,
    escape,
    csi,
    string,
    string_escape,
};

fn removeLastUtf8(out: []u8, n: *usize, line_start: usize) void {
    if (n.* <= line_start) return;
    n.* -= 1;
    while (n.* > line_start and (out[n.*] & 0xc0) == 0x80) n.* -= 1;
}

fn sanitizeTerminalText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, text.len);
    var n: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var state: TerminalSanitizeState = .text;
    var csi_param: usize = 0;
    var csi_has_param = false;

    while (i < text.len) {
        const byte = text[i];
        switch (state) {
            .text => {
                if (byte == 0x1b) {
                    state = .escape;
                    i += 1;
                    continue;
                }
                if (byte == '\r') {
                    // PTYs normally emit CRLF for a real newline.  A lone CR
                    // is terminal redraw: subsequent text overwrites the
                    // current line rather than being appended to it.
                    if (i + 1 < text.len and text[i + 1] == '\n') {
                        i += 1;
                        continue;
                    }
                    n = line_start;
                    i += 1;
                    continue;
                }
                if (byte == '\n') {
                    out[n] = '\n';
                    n += 1;
                    line_start = n;
                    i += 1;
                    continue;
                }
                if (byte == 0x08) {
                    removeLastUtf8(out, &n, line_start);
                    i += 1;
                    continue;
                }
                if (byte < 0x20 or byte == 0x7f) {
                    if (byte == '\t') {
                        out[n] = byte;
                        n += 1;
                    }
                    i += 1;
                    continue;
                }
                if (byte < 0x80) {
                    out[n] = byte;
                    n += 1;
                    i += 1;
                    continue;
                }

                // Copy UTF-8 atomically. Invalid or truncated sequences are
                // skipped instead of feeding broken byte fragments to vaxis.
                const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
                    i += 1;
                    continue;
                };
                if (i + sequence_len > text.len) break;
                _ = std.unicode.utf8Decode(text[i .. i + sequence_len]) catch {
                    i += 1;
                    continue;
                };
                @memcpy(out[n .. n + sequence_len], text[i .. i + sequence_len]);
                n += sequence_len;
                i += sequence_len;
            },
            .escape => {
                if (byte == '[') {
                    state = .csi;
                    csi_param = 0;
                    csi_has_param = false;
                } else {
                    state = switch (byte) {
                        ']', 'P', '^', '_' => .string,
                        else => .text,
                    };
                }
                i += 1;
            },
            .csi => {
                if (byte >= '0' and byte <= '9') {
                    csi_has_param = true;
                    csi_param = @min(csi_param * 10 + (byte - '0'), 65535);
                    i += 1;
                    continue;
                }
                if (byte == ';' or (byte >= 0x20 and byte <= 0x3f)) {
                    // We only need the first numeric argument for the cursor
                    // operations below; style and extended parameters can be
                    // ignored for the plain-text preview.
                    i += 1;
                    continue;
                }
                if (byte >= 0x40 and byte <= 0x7e) {
                    const count = if (csi_has_param and csi_param != 0) csi_param else 1;
                    switch (byte) {
                        // Cursor backward. zsh uses this heavily while
                        // recoloring an already-echoed command. Rewinding the
                        // plain-text line prevents duplicate command text.
                        'D' => {
                            var remaining = count;
                            while (remaining > 0 and n > line_start) : (remaining -= 1) {
                                removeLastUtf8(out, &n, line_start);
                            }
                        },
                        // Horizontal absolute column 1 and erase-whole-line
                        // both mean the next visible text starts a fresh line.
                        'G', '`' => if (count <= 1) {
                            n = line_start;
                        },
                        'K' => if (csi_param == 1 or csi_param == 2) {
                            n = line_start;
                        },
                        else => {},
                    }
                    state = .text;
                }
                i += 1;
            },
            .string => {
                if (byte == 0x07) {
                    state = .text;
                } else if (byte == 0x1b) {
                    state = .string_escape;
                }
                i += 1;
            },
            .string_escape => {
                if (byte == '\\') {
                    state = .text;
                } else if (byte != 0x1b) {
                    state = .string;
                }
                i += 1;
            },
        }
    }

    return out[0..n];
}

fn sortJobs(items: []jobs.ListItem) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].job_id > items[j].job_id) : (j -= 1) std.mem.swap(jobs.ListItem, &items[j - 1], &items[j]);
    }
}

fn sortShells(items: []shells.ListItem) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].shell_id > items[j].shell_id) : (j -= 1) std.mem.swap(shells.ListItem, &items[j - 1], &items[j]);
    }
}
