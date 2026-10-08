const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const client = @import("../device/client.zig");
const control = @import("../control/state.zig");
const events = @import("../control/events.zig");
const executions = @import("../executions/manager.zig");
const jobs = @import("../tools/jobs.zig");
const shells = @import("../tools/shells.zig");

pub const Action = union(enum) { quit, attach: u64 };
const View = enum { exec, job, shell, events };
const Kind = enum { exec_active, exec_history, job, shell };
const Stream = enum { all, stdout, stderr };
const Ref = struct {
    kind: Kind,
    id: u64,
    fn same(a: Ref, b: Ref) bool {
        const a_exec = a.kind == .exec_active or a.kind == .exec_history;
        const b_exec = b.kind == .exec_active or b.kind == .exec_history;
        return a.id == b.id and (a.kind == b.kind or (a_exec and b_exec));
    }
};
const Row = struct {
    ref: Ref,
    command: []const u8,
    cwd: []const u8,
    status: []const u8,
    running: bool,
    failed: bool = false,
    exit_code: ?u8 = null,
    note: []const u8 = "",
};
const accent: vaxis.Cell.Style = .{ .fg = .{ .index = 6 }, .bold = true };
const muted: vaxis.Cell.Style = .{ .dim = true };

// Owned across attach/detach; no frame-arena pointers survive a draw.
pub const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    device_name: []const u8 = "local",
    view: View = .exec,
    selected: usize = 0,
    selected_ref: ?Ref = null,
    pending_stop: ?Ref = null,
    selected_running: bool = false,
    frozen_truncated: bool = false,
    count: usize = 0,
    offset: usize = 0,
    page_size: usize = 1,
    detail_open: bool = false,
    output_focus: bool = false,
    help: bool = false,
    confirm: enum { none, stop, quit } = .none,
    filtering: bool = false,
    filter: [128]u8 = @splat(0),
    filter_len: usize = 0,
    searching: bool = false,
    search: [128]u8 = @splat(0),
    search_len: usize = 0,
    stream: Stream = .all,
    follow: bool = true,
    log_top: usize = 0,
    log_count: usize = 0,
    log_page: usize = 1,
    frozen: ?[]const u8 = null,
    attach_request: ?u64 = null,
    status: [200]u8 = @splat(0),
    status_len: usize = 0,

    pub fn deinit(self: *Model) void {
        self.resetOutput();
    }
    fn resetOutput(self: *Model) void {
        if (self.frozen) |text| self.allocator.free(text);
        self.frozen = null;
        self.frozen_truncated = false;
        self.follow = true;
        self.log_top = 0;
        self.log_count = 0;
    }
    fn widget(self: *Model) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = eventHandler, .drawFn = drawFn };
    }
    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
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
            .key_press => |key| {
                try self.handleKey(ctx, key);
            },
            else => {},
        }
    }
    fn setStatus(self: *Model, text: []const u8) void {
        self.status_len = @min(text.len, self.status.len);
        @memcpy(self.status[0..self.status_len], text[0..self.status_len]);
    }
    fn switchView(self: *Model, view: View) void {
        if (view == self.view) return;
        self.view = view;
        self.selected = 0;
        self.selected_ref = null;
        self.offset = 0;
        self.detail_open = false;
        self.output_focus = false;
        self.filter_len = 0;
        self.search_len = 0;
        self.status_len = 0;
        self.resetOutput();
    }
    fn move(self: *Model, backwards: bool, amount: usize) void {
        if (self.output_focus or self.detail_open or self.view == .events) {
            self.follow = false;
            self.log_top = if (backwards) self.log_top -| amount else @min(self.log_top +| amount, self.log_count -| self.log_page);
        } else {
            self.selected = if (backwards) self.selected -| amount else @min(self.selected +| amount, self.count -| 1);
            self.selected_ref = null;
            self.resetOutput();
        }
    }
    fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        defer ctx.consumeAndRedraw();
        if (self.confirm != .none) {
            const action = self.confirm;
            self.confirm = .none;
            if (key.matches('y', .{})) {
                if (action == .quit) ctx.quit = true else try self.stopSelected();
            }
            return;
        }
        if (self.help) {
            self.help = false;
            return;
        }
        if (self.filtering or self.searching) {
            const searching = self.searching;
            const buffer = if (searching) &self.search else &self.filter;
            const len = if (searching) &self.search_len else &self.filter_len;
            if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{})) {
                self.filtering = false;
                self.searching = false;
                return;
            }
            if (key.matches(vaxis.Key.backspace, .{})) {
                removeLastUtf8(buffer, len, 0);
            } else if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= 0x20 and key.codepoint < 0x110000 and !(key.codepoint >= 0xe000 and key.codepoint <= 0xf8ff)) {
                var bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &bytes) catch return;
                if (len.* + n <= buffer.len) {
                    @memcpy(buffer[len.*..][0..n], bytes[0..n]);
                    len.* += n;
                }
            }
            if (searching) {
                self.log_top = 0;
                self.follow = false;
            } else {
                self.selected = 0;
                self.selected_ref = null;
                self.offset = 0;
                self.resetOutput();
            }
            return;
        }
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            self.confirm = .quit;
            return;
        }
        if (key.matches('?', .{})) {
            self.help = true;
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.detail_open) {
                self.detail_open = false;
                self.output_focus = false;
            } else if (self.search_len > 0) {
                self.search_len = 0;
            } else if (self.output_focus) {
                self.output_focus = false;
            } else {
                self.filter_len = 0;
            }
            return;
        }
        if (key.matches('1', .{}) or key.matches('e', .{})) {
            self.switchView(.exec);
            return;
        }
        if (key.matches('2', .{})) {
            self.switchView(.job);
            return;
        }
        if (key.matches('3', .{}) or key.matches('s', .{})) {
            self.switchView(.shell);
            return;
        }
        if (key.matches('4', .{})) {
            self.switchView(.events);
            return;
        }
        if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
            self.switchView(@enumFromInt((@as(u8, @intFromEnum(self.view)) + 1) % 4));
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (self.detail_open) {
                self.detail_open = false;
                self.output_focus = false;
            } else self.output_focus = !self.output_focus;
            return;
        }
        if (key.matches('/', .{})) {
            if (self.output_focus or self.detail_open or self.view == .events) self.searching = true else self.filtering = true;
            return;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            self.move(false, 1);
            return;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            self.move(true, 1);
            return;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            self.move(true, if (self.output_focus or self.detail_open or self.view == .events) self.log_page else self.page_size);
            return;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            self.move(false, if (self.output_focus or self.detail_open or self.view == .events) self.log_page else self.page_size);
            return;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            self.move(true, std.math.maxInt(usize));
            return;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            if (self.output_focus or self.detail_open or self.view == .events) self.resetOutput() else self.move(false, self.count);
            return;
        }
        if (key.matches('f', .{})) {
            if (self.follow) self.follow = false else self.resetOutput();
            return;
        }
        if (key.matches('o', .{})) {
            self.stream = @enumFromInt((@as(u8, @intFromEnum(self.stream)) + 1) % 3);
            self.resetOutput();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.detail_open = !self.detail_open;
            self.output_focus = self.detail_open;
            return;
        }
        if (key.matches('t', .{})) {
            if (control.snapshot(self.io).owner == .agent) {
                _ = control.take(self.io);
                self.setStatus("Human control: new agent mutations blocked; running work continues");
                events.record(self.io, .human, "control.taken", .control, null, "Human control enabled from TUI");
            } else {
                _ = control.release(self.io);
                self.setStatus("Agent control restored");
                events.record(self.io, .human, "control.released", .control, null, "Agent control restored from TUI");
            }
            return;
        }
        if (key.matches('x', .{})) {
            if (control.snapshot(self.io).owner != .human) {
                self.setStatus("Press t to take control before stopping work");
                return;
            }
            if (!self.selected_running) {
                self.setStatus("Selected resource is not running");
                return;
            }
            if (self.selected_ref != null and self.view != .events) {
                self.pending_stop = self.selected_ref;
                self.confirm = .stop;
            }
            return;
        }
        if (key.matches('a', .{}) and self.view == .shell) {
            if (control.snapshot(self.io).owner != .human) {
                self.setStatus("Press t to take control before attach");
                return;
            }
            if (!self.selected_running) {
                self.setStatus("Selected shell is not running");
                return;
            }
            const ref = self.selected_ref orelse return;
            const offsets = shells.outputOffsets(ref.id) catch {
                self.setStatus("Shell no longer available");
                return;
            };
            _ = offsets;
            self.attach_request = ref.id;
            ctx.quit = true;
        }
    }
    fn stopSelected(self: *Model) !void {
        if (control.snapshot(self.io).owner != .human) {
            self.setStatus("Human control required");
            return;
        }
        const ref = self.pending_stop orelse return;
        switch (ref.kind) {
            .exec_active => executions.requestTerminate(self.io, ref.id, .human) catch |err| {
                self.setStatus(@errorName(err));
                return;
            },
            .job => {
                _ = jobs.stopBy(ref.id, .human) catch |err| {
                    self.setStatus(@errorName(err));
                    return;
                };
            },
            .shell => {
                _ = shells.killBy(ref.id, .human) catch |err| {
                    self.setStatus(@errorName(err));
                    return;
                };
            },
            .exec_history => {
                self.setStatus("Completed executions are read-only");
                return;
            },
        }
        self.setStatus("Stop requested; resource status will update automatically");
    }
    fn rows(self: *Model, allocator: std.mem.Allocator) ![]Row {
        var result: std.ArrayList(Row) = .empty;
        switch (self.view) {
            .exec => {
                const active = try executions.list(allocator, self.io);
                const history = try executions.historyRecent(allocator, self.io, executions.history_capacity);
                for (active.items) |item| try result.append(allocator, .{ .ref = .{ .kind = .exec_active, .id = item.executionId }, .command = item.command, .cwd = item.cwd orelse "-", .status = if (item.cancelRequested) "stopping" else "running", .running = true });
                var i = history.items.len;
                while (i > 0) {
                    i -= 1;
                    const item = history.items[i];
                    // An execution may finish between the two snapshots.
                    var duplicate = false;
                    for (result.items) |row| {
                        if (row.ref.id == item.executionId) duplicate = true;
                    }
                    if (duplicate) continue;
                    try result.append(allocator, .{ .ref = .{ .kind = .exec_history, .id = item.executionId }, .command = item.command, .cwd = item.cwd orelse "-", .status = item.status.name(), .running = false, .failed = item.status == .failed or (item.exitCode orelse 0) != 0, .exit_code = item.exitCode, .note = item.termination });
                }
            },
            .job => {
                const list = try jobs.list(allocator);
                sortJobs(list.items);
                for (list.items) |item| try result.append(allocator, .{ .ref = .{ .kind = .job, .id = item.job_id }, .command = try std.mem.join(allocator, " ", try std.mem.concat(allocator, []const u8, &.{ &.{item.program}, item.args })), .cwd = item.cwd orelse "-", .status = item.status.name(), .running = item.status == .running, .failed = item.status == .failed or (item.exit_code orelse 0) != 0, .exit_code = item.exit_code });
            },
            .shell => {
                const list = try shells.list(allocator);
                sortShells(list.items);
                for (list.items) |item| try result.append(allocator, .{ .ref = .{ .kind = .shell, .id = item.shell_id }, .command = item.shell, .cwd = item.initial_cwd orelse "-", .status = item.status.name(), .running = item.status == .running, .failed = item.status == .failed or (item.exit_code orelse 0) != 0, .exit_code = item.exit_code, .note = try std.fmt.allocPrint(allocator, "{d} x {d}  |  a attach  |  Ctrl+] detach", .{ item.cols, item.rows }) });
            },
            .events => {},
        }
        var n: usize = 0;
        for (result.items) |row| {
            if (!contains(row.command, self.filter[0..self.filter_len]) and !contains(row.cwd, self.filter[0..self.filter_len])) continue;
            result.items[n] = row;
            n += 1;
        }
        return result.items[0..n];
    }
    fn reconcile(self: *Model, items: []const Row) void {
        const previous = self.selected_ref;
        if (previous) |ref| {
            for (items, 0..) |row, i| {
                if (ref.same(row.ref)) {
                    self.selected = i;
                    break;
                }
            }
        }
        self.count = items.len;
        self.selected = @min(self.selected, items.len -| 1);
        self.selected_ref = if (items.len > 0) items[self.selected].ref else null;
        self.selected_running = items.len > 0 and items[self.selected].running;
        if (previous) |ref| {
            if (self.selected_ref == null or !ref.same(self.selected_ref.?)) self.resetOutput();
        }
        self.offset = viewport(self.offset, self.selected, self.page_size, items.len);
    }
    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.draw(ctx) catch |err| {
            const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
            putText(ctx, surface, 0, 0, @errorName(err), accent, surface.size.width);
            return surface;
        };
    }
    fn draw(self: *Model, ctx: vxfw.DrawContext) !vxfw.Surface {
        const size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width < 24 or size.height < 10) {
            putText(ctx, surface, 0, 0, "Enlarge terminal (24x10)", accent, size.width);
            return surface;
        }
        const human = control.snapshot(self.io).owner == .human;
        const title = try std.fmt.allocPrint(ctx.arena, "zshell / {s}", .{self.device_name});
        const owner = if (human) " HUMAN " else " AGENT ";
        putText(ctx, surface, 0, 1, title, accent, size.width -| 12);
        putText(ctx, surface, 0, size.width - 9, owner, .{ .bold = true, .fg = .{ .index = if (human) 3 else 6 } }, 8);
        const connection = client.connectionStatus(self.io);
        putText(ctx, surface, 1, 1, connection, muted, size.width - 2);
        const labels = [_][]const u8{ "1 Exec", "2 Jobs", "3 Shells", "4 Events" };
        var col: u16 = 1;
        for (labels, 0..) |label, i| {
            putText(ctx, surface, 2, col, label, if (i == @intFromEnum(self.view)) .{ .reverse = true, .bold = true } else muted, size.width -| col);
            col += @intCast(label.len + 3);
        }
        drawRule(surface, 3, size.width);
        const bottom = size.height - 3;
        const height = bottom - 4;
        self.page_size = @max(1, height -| 2);
        const items = try self.rows(ctx.arena);
        if (self.view != .events) self.reconcile(items);
        if (self.help) {
            const lines = [_][]const u8{ "KEYBOARD", "1-4 views    Shift+Tab next view", "Tab focus list/output    Enter expand", "j/k or arrows move    PgUp/PgDn page", "Home first    End latest / resume follow", "/ filter list or search output (case-insensitive)", "o output stream: all / stdout / stderr", "f pause/resume output    Esc back / clear", "t take/release control    x stop selected", "a attach shell    Ctrl+] detach", "q stop Core (confirmation)    ? help", "Press any key to return" };
            for (lines, 0..) |line, i| {
                if (4 + i >= bottom) break;
                putText(ctx, surface, @intCast(4 + i), 2, line, if (i == 0) accent else .{}, size.width - 4);
            }
        } else if (self.view == .events) {
            const snapshot = try events.snapshot(ctx.arena, self.io);
            var text: std.Io.Writer.Allocating = .init(ctx.arena);
            for (snapshot.items) |event| try text.writer.print("#{d} [{s}] {s} {s}#{?d}: {s}\n", .{ event.seq, event.source, event.kind, event.resource, event.resourceId, event.message });
            try self.drawOutput(ctx, surface, 4, 1, height, size.width - 2, text.written(), false);
        } else {
            const wide = size.width >= 96;
            const list_width: u16 = if (wide) @max(30, size.width / 3) else size.width;
            if (!self.detail_open) {
                const header = try std.fmt.allocPrint(ctx.arena, "{s}  {d}/{d}  /{s}", .{ if (self.output_focus) "RESOURCES" else "> RESOURCES", if (items.len == 0) @as(usize, 0) else self.selected + 1, items.len, self.filter[0..self.filter_len] });
                putText(ctx, surface, 4, 1, header, if (self.output_focus) muted else accent, list_width - 2);
                if (items.len == 0) putText(ctx, surface, 6, 1, "No matching resources", muted, list_width - 2);
                const end = @min(items.len, self.offset + self.page_size);
                for (items[self.offset..end], 0..) |row, i| {
                    const y: u16 = @intCast(6 + i);
                    const selected = self.offset + i == self.selected;
                    const style: vaxis.Cell.Style = if (selected) .{ .reverse = true } else .{};
                    fillStyle(surface, y, 1, list_width - 2, style);
                    const line = try std.fmt.allocPrint(ctx.arena, "{s} {s} #{d} {s}", .{ if (selected) ">" else " ", if (row.running) "●" else if (row.failed) "×" else "✓", row.ref.id, row.command });
                    putText(ctx, surface, y, 1, line, style, list_width - 2);
                    if (!selected) putText(ctx, surface, y, 3, if (row.running) "●" else if (row.failed) "×" else "✓", .{ .fg = .{ .index = if (row.failed) 1 else if (row.running) 2 else 7 } }, 1);
                }
            }
            if (wide or self.detail_open) {
                const detail_col: u16 = if (self.detail_open) 1 else list_width + 2;
                if (!self.detail_open) drawVerticalRule(surface, 4, bottom, list_width);
                if (items.len > 0) try self.drawDetail(ctx, surface, items[self.selected], 4, detail_col, height, size.width - detail_col - 1);
            } else if (self.output_focus) {
                // A narrow terminal has one pane; make focus changes visible.
                self.detail_open = true;
            }
        }
        drawRule(surface, bottom, size.width);
        var footer: []const u8 = if (human) "Human control: new agent mutations blocked; running work continues" else "Agent control: observing activity";
        if (self.status_len > 0) footer = self.status[0..self.status_len];
        if (self.filtering) footer = try std.fmt.allocPrint(ctx.arena, "Filter: {s}_  Enter done", .{self.filter[0..self.filter_len]});
        if (self.searching or self.search_len > 0) footer = try std.fmt.allocPrint(ctx.arena, "Search: {s}{s}  Esc clear", .{ self.search[0..self.search_len], if (self.searching) "_" else "" });
        if (self.confirm == .quit) footer = "Stop Core and disconnect this device? y confirm / any other key cancel";
        if (self.confirm == .stop) {
            if (self.pending_stop) |ref| footer = try std.fmt.allocPrint(ctx.arena, "Stop {s} #{d}? y confirm / any other key cancel", .{ @tagName(ref.kind), ref.id });
        }
        putText(ctx, surface, bottom + 1, 1, footer, if (self.confirm != .none or human) .{ .fg = .{ .index = 3 } } else muted, size.width - 2);
        const hints = if (size.width < 80) "1-4 Views  Tab Focus  / Search  ? Help" else if (self.output_focus or self.detail_open or self.view == .events) "↑↓ Scroll  / Search  o Stream  f Follow  End Latest  Tab List  ? Help" else if (human) "↑↓ Move  Enter Expand  / Filter  t Release  x Stop  a Attach  ? Help" else "↑↓ Move  Enter Expand  / Filter  t Take control  Tab Output  ? Help";
        putText(ctx, surface, bottom + 2, 1, hints, .{}, size.width - 2);
        return surface;
    }
    fn drawDetail(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, item: Row, top: u16, col: u16, height: u16, width: u16) !void {
        const end = top + height;
        const heading = try std.fmt.allocPrint(ctx.arena, "#{d}  {s}", .{ item.ref.id, item.status });
        putText(ctx, surface, top, col, heading, accent, width);
        var row = drawWrapped(ctx, surface, top + 1, col, @min(end, top + if (self.detail_open) @max(@as(u16, 3), height / 2) else @as(u16, 4)), width, item.command);
        row = drawField(ctx, surface, row, col, end, width, "cwd", item.cwd);
        if (item.exit_code) |code| row = drawField(ctx, surface, row, col, end, width, "exit", try std.fmt.allocPrint(ctx.arena, "{d}", .{code}));
        if (item.note.len > 0 and row < end) {
            putText(ctx, surface, row, col, item.note, muted, width);
            row += 1;
        }
        if (row >= end) return;
        row += 1;
        if (row >= end) return;
        if (self.frozen) |text| {
            try self.drawOutput(ctx, surface, row, col, end - row, width, text, false);
            return;
        }
        switch (item.ref.kind) {
            .job => {
                const logs = jobs.logs(ctx.arena, item.ref.id, null, null) catch |err| {
                    putText(ctx, surface, row, col, @errorName(err), muted, width);
                    return;
                };
                const text = try self.outputText(ctx.arena, logs.stdout, logs.stderr);
                try self.drawOutput(ctx, surface, row, col, end - row, width, text, logs.stdout_truncated or logs.stderr_truncated);
            },
            .shell => {
                const output = shells.read(ctx.arena, item.ref.id, null, null) catch |err| {
                    putText(ctx, surface, row, col, @errorName(err), muted, width);
                    return;
                };
                const text = try self.outputText(ctx.arena, output.stdout, output.stderr);
                try self.drawOutput(ctx, surface, row, col, end - row, width, text, output.stdout_truncated or output.stderr_truncated);
            },
            else => {
                putText(ctx, surface, row, col, "Exec output is not retained by Core.", muted, width);
                if (row + 1 < end) putText(ctx, surface, row + 1, col, "Use Jobs for searchable output history.", muted, width);
            },
        }
    }
    fn outputText(self: *Model, allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
        const text = switch (self.stream) {
            .stdout => stdout,
            .stderr => stderr,
            .all => if (stderr.len == 0) stdout else try std.fmt.allocPrint(allocator, "[stdout]\n{s}\n[stderr - grouped by stream]\n{s}", .{ stdout, stderr }),
        };
        return sanitizeTerminalText(allocator, text);
    }
    fn drawOutput(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, top: u16, col: u16, height: u16, width: u16, current: []const u8, truncated: bool) !void {
        if (height == 0) return;
        if (!self.follow and self.frozen == null) {
            self.frozen = try self.allocator.dupe(u8, current);
            self.frozen_truncated = truncated;
        }
        const text = self.frozen orelse current;
        var lines: std.ArrayList([]const u8) = .empty;
        var iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (iter.next()) |line| {
            if (contains(line, self.search[0..self.search_len])) try lines.append(ctx.arena, line);
        }
        if (text.len == 0) lines.clearRetainingCapacity();
        self.log_page = @max(1, height -| 1);
        self.log_count = lines.items.len;
        const last = lines.items.len -| self.log_page;
        self.log_top = if (self.follow) last else @min(self.log_top, last);
        const header = try std.fmt.allocPrint(ctx.arena, "{s}{s}  {s}  {d}/{d}{s}", .{ if (self.output_focus or self.detail_open or self.view == .events) "> " else "", if (self.view == .events) "EVENTS" else @tagName(self.stream), if (self.follow) "LIVE" else "PAUSED", if (lines.items.len == 0) @as(usize, 0) else self.log_top + 1, lines.items.len, if (truncated or self.frozen_truncated) "  [older output discarded]" else "" });
        putText(ctx, surface, top, col, header, accent, width);
        if (height <= 1) return;
        if (lines.items.len == 0) {
            putText(ctx, surface, top + 1, col, if (self.search_len > 0) "No matching lines" else "Waiting for output", muted, width);
            return;
        }
        const end = @min(lines.items.len, self.log_top + height - 1);
        for (lines.items[self.log_top..end], 0..) |line, i| putText(ctx, surface, top + 1 + @as(u16, @intCast(i)), col, line, .{}, width);
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, model: *Model) !Action {
    var buffer: [4096]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, environ_map, &buffer);
    defer app.deinit();
    model.attach_request = null;
    model.device_name = environ_map.get("ZSHELL_DEVICE_NAME") orelse "local";
    try app.run(model.widget(), .{ .framerate = 30 });
    if (model.attach_request) |id| return .{ .attach = id };
    return .quit;
}
fn contains(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    }
    return false;
}
fn viewport(offset: usize, selected: usize, height: usize, count: usize) usize {
    var start = @min(offset, count -| height);
    if (selected < start) start = selected;
    if (selected >= start + height) start = selected + 1 -| height;
    return start;
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
    var consumed: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme_info| {
        const grapheme = grapheme_info.bytes(text);
        if (std.mem.eql(u8, grapheme, "\n") or std.mem.eql(u8, grapheme, "\r")) break;
        const grapheme_width: u8 = @intCast(@max(1, ctx.stringWidth(grapheme)));
        consumed += grapheme.len;
        if (col +| grapheme_width > limit or (col +| grapheme_width == limit and consumed < text.len)) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = "…", .width = 1 }, .style = style });
            break;
        }
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

fn drawWrapped(ctx: vxfw.DrawContext, surface: vxfw.Surface, start: u16, col: u16, end: u16, width: u16, text: []const u8) u16 {
    if (start >= end or width == 0) return start;
    var row = start;
    var x: u16 = 0;
    var consumed: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |info| {
        const grapheme = info.bytes(text);
        const w: u16 = @intCast(@max(1, ctx.stringWidth(grapheme)));
        if (std.mem.eql(u8, grapheme, "\n") or x + w > width) {
            row += 1;
            x = 0;
        }
        if (row >= end) break;
        consumed += grapheme.len;
        if (std.mem.eql(u8, grapheme, "\n")) continue;
        if (row + 1 == end and x + w >= width and consumed < text.len) {
            putText(ctx, surface, row, col + x, "…", .{}, 1);
            break;
        }
        putText(ctx, surface, row, col + x, grapheme, .{}, width - x);
        x += w;
    }
    return @min(end, row + 1);
}

fn drawField(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: u16, col: u16, end: u16, width: u16, name: []const u8, value: []const u8) u16 {
    if (row >= end) return row;
    const label = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ name, value }) catch return row;
    putText(ctx, surface, row, col, label, .{}, width);
    return row + 1;
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
    errdefer allocator.free(out);
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

    return try allocator.realloc(out, n);
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

test "selection tracks execution identity through reordering and completion" {
    var model: Model = .{ .allocator = std.testing.allocator, .io = std.testing.io, .page_size = 2 };
    defer model.deinit();
    const running: Row = .{ .ref = .{ .kind = .exec_active, .id = 7 }, .command = "test", .cwd = "/", .status = "running", .running = true };
    var finished = running;
    finished.ref.kind = .exec_history;
    finished.running = false;
    var another = running;
    another.ref.id = 8;
    model.reconcile(&.{running});
    model.reconcile(&.{ another, finished });
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    try std.testing.expectEqual(Kind.exec_history, model.selected_ref.?.kind);
    model.reconcile(&.{});
    try std.testing.expect(model.selected_ref == null);
    try std.testing.expectEqual(@as(usize, 0), model.offset);
}

test "viewport keeps selected resource visible and clamps after shrink" {
    try std.testing.expectEqual(@as(usize, 16), viewport(0, 20, 5, 30));
    try std.testing.expectEqual(@as(usize, 2), viewport(16, 2, 5, 30));
    try std.testing.expectEqual(@as(usize, 0), viewport(16, 1, 5, 2));
}

test "paused logs survive navigation and release owned snapshot on resume" {
    var model: Model = .{ .allocator = std.testing.allocator, .io = std.testing.io, .output_focus = true, .log_count = 100, .log_page = 10, .log_top = 90 };
    defer model.deinit();
    model.frozen = try std.testing.allocator.dupe(u8, "frozen output");
    model.move(true, 10);
    try std.testing.expect(!model.follow);
    try std.testing.expectEqual(@as(usize, 80), model.log_top);
    try std.testing.expectEqualStrings("frozen output", model.frozen.?);
    model.resetOutput();
    try std.testing.expect(model.follow and model.frozen == null);
}

test "search and terminal sanitation preserve UTF-8 while removing escapes" {
    try std.testing.expect(contains("Build FAILED 中文", "failed"));
    try std.testing.expect(contains("Build 中文", "中文"));
    try std.testing.expect(!contains("abc", "abcd"));
    const clean = try sanitizeTerminalText(std.testing.allocator, "\x1b[31m中文\x1b[0m\r\nold\rnew\n\x1b]0;title\x07done");
    defer std.testing.allocator.free(clean);
    try std.testing.expectEqualStrings("中文\nnew\ndone", clean);
    var buffer: [16]u8 = @splat(0);
    @memcpy(buffer[0..6], "中文");
    var len: usize = 6;
    removeLastUtf8(&buffer, &len, 0);
    try std.testing.expectEqualStrings("中", buffer[0..len]);
}
