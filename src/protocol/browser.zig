const std = @import("std");
const browser = @import("../tools/browser.zig");

pub const Outcome = enum {
    ok,
    bad_request,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    operation: []const u8,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !?Outcome {
    if (std.mem.eql(u8, operation, "browser_status")) {
        return @as(?Outcome, try browserStatus(arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_start")) {
        return @as(?Outcome, try browserStart(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_open")) {
        return @as(?Outcome, try browserOpen(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_snapshot")) {
        return @as(?Outcome, try browserSnapshot(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_click")) {
        return @as(?Outcome, try browserClick(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_fill")) {
        return @as(?Outcome, try browserFill(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_select")) {
        return @as(?Outcome, try browserSelect(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_check")) {
        return @as(?Outcome, try browserCheck(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_press")) {
        return @as(?Outcome, try browserPress(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_upload")) {
        return @as(?Outcome, try browserUpload(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_download")) {
        return @as(?Outcome, try browserDownload(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_tabs")) {
        return @as(?Outcome, try browserTabs(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_wait")) {
        return @as(?Outcome, try browserWait(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_get")) {
        return @as(?Outcome, try browserGet(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_screenshot")) {
        return @as(?Outcome, try browserScreenshot(allocator, arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_takeover")) {
        return @as(?Outcome, try browserTakeover(arguments, writer));
    }
    if (std.mem.eql(u8, operation, "browser_close")) {
        return @as(?Outcome, try browserClose(allocator, arguments, writer));
    }
    return null;
}

fn browserStatus(arguments: ?std.json.Value, writer: *std.Io.Writer) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;
    try writeSuccess(writer, browser.status(), false);
    return .ok;
}

fn browserStart(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const input = try parseStartInput(arguments, writer) orelse return .bad_request;
    const result = browser.start(allocator, input) catch |err| {
        try writeBrowserFailure(writer, err);
        return .ok;
    };
    defer result.deinit(allocator);
    return writeEngineResult(allocator, result, writer);
}

fn browserOpen(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const url = try parseRequiredString(arguments, "url", "browser_open", writer) orelse return .bad_request;
    return runSimple(allocator, &.{ "open", url }, writer);
}

fn browserSnapshot(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const interactive_only = try parseOptionalBoolObject(
        arguments,
        "interactiveOnly",
        true,
        "browser_snapshot",
        writer,
    ) orelse return .bad_request;
    if (interactive_only) return runSimple(allocator, &.{ "snapshot", "-i" }, writer);
    return runSimple(allocator, &.{"snapshot"}, writer);
}

fn browserClick(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "browser_click requires arguments");
        return .bad_request;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return .bad_request;
        },
    };
    if (!hasOnlyFields(object, &.{ "ref", "newTab" })) {
        try writeInvalidRequest(writer, "Invalid browser_click arguments");
        return .bad_request;
    }
    const ref_text = getString(object, "ref") orelse {
        try writeInvalidRequest(writer, "ref must be a string");
        return .bad_request;
    };
    const ref = try normalizeRef(allocator, ref_text, writer) orelse return .bad_request;
    defer if (ref.owned) |owned| allocator.free(owned);
    const new_tab = try optionalBool(object, "newTab", false, writer) orelse return .bad_request;
    if (new_tab) return runSimple(allocator, &.{ "click", ref.value, "--new-tab" }, writer);
    return runSimple(allocator, &.{ "click", ref.value }, writer);
}

fn browserFill(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const pair = try parseRefAndString(allocator, arguments, "text", "browser_fill", writer) orelse return .bad_request;
    defer if (pair.owned_ref) |owned| allocator.free(owned);
    return runSimple(allocator, &.{ "fill", pair.ref, pair.value }, writer);
}

fn browserSelect(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const pair = try parseRefAndString(allocator, arguments, "value", "browser_select", writer) orelse return .bad_request;
    defer if (pair.owned_ref) |owned| allocator.free(owned);
    return runSimple(allocator, &.{ "select", pair.ref, pair.value }, writer);
}

fn browserCheck(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "browser_check requires arguments");
        return .bad_request;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return .bad_request;
        },
    };
    if (!hasOnlyFields(object, &.{ "ref", "checked" })) {
        try writeInvalidRequest(writer, "Invalid browser_check arguments");
        return .bad_request;
    }
    const ref_text = getString(object, "ref") orelse {
        try writeInvalidRequest(writer, "ref must be a string");
        return .bad_request;
    };
    const ref = try normalizeRef(allocator, ref_text, writer) orelse return .bad_request;
    defer if (ref.owned) |owned| allocator.free(owned);
    const checked = try optionalBool(object, "checked", true, writer) orelse return .bad_request;
    return runSimple(allocator, if (checked) &.{ "check", ref.value } else &.{ "uncheck", ref.value }, writer);
}

fn browserPress(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const key = try parseRequiredString(arguments, "key", "browser_press", writer) orelse return .bad_request;
    return runSimple(allocator, &.{ "press", key }, writer);
}

fn browserUpload(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const value = arguments orelse {
        try writeInvalidRequest(writer, "browser_upload requires arguments");
        return .bad_request;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return .bad_request;
        },
    };
    if (!hasOnlyFields(object, &.{ "ref", "files" })) {
        try writeInvalidRequest(writer, "Invalid browser_upload arguments");
        return .bad_request;
    }
    const ref_text = getString(object, "ref") orelse {
        try writeInvalidRequest(writer, "ref must be a string");
        return .bad_request;
    };
    const ref = try normalizeRef(allocator, ref_text, writer) orelse return .bad_request;
    defer if (ref.owned) |owned| allocator.free(owned);

    const files_value = object.get("files") orelse {
        try writeInvalidRequest(writer, "files is required");
        return .bad_request;
    };
    const files_array = switch (files_value) {
        .array => |array| array,
        else => {
            try writeInvalidRequest(writer, "files must be an array of paths");
            return .bad_request;
        },
    };
    if (files_array.items.len == 0 or files_array.items.len > 16) {
        try writeInvalidRequest(writer, "files must contain between 1 and 16 paths");
        return .bad_request;
    }

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "upload", ref.value });
    for (files_array.items) |file_value| {
        const path = switch (file_value) {
            .string => |text| text,
            else => {
                try writeInvalidRequest(writer, "each file path must be a string");
                return .bad_request;
            },
        };
        if (path.len == 0) {
            try writeInvalidRequest(writer, "file paths must not be empty");
            return .bad_request;
        }
        try args.append(allocator, path);
    }
    return runSimple(allocator, args.items, writer);
}

fn browserDownload(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const pair = try parseRefAndString(allocator, arguments, "path", "browser_download", writer) orelse return .bad_request;
    defer if (pair.owned_ref) |owned| allocator.free(owned);
    if (pair.value.len == 0) {
        try writeInvalidRequest(writer, "download path must not be empty");
        return .bad_request;
    }
    return runSimple(allocator, &.{ "download", pair.ref, pair.value }, writer);
}

fn browserTabs(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    var action: []const u8 = "list";
    var tab: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var label: ?[]const u8 = null;

    if (arguments) |value| {
        const object = switch (value) {
            .object => |object| object,
            else => {
                try writeInvalidRequest(writer, "arguments must be an object");
                return .bad_request;
            },
        };
        if (!hasOnlyFields(object, &.{ "action", "tab", "url", "label" })) {
            try writeInvalidRequest(writer, "Invalid browser_tabs arguments");
            return .bad_request;
        }
        if (object.get("action") != null) {
            action = getString(object, "action") orelse {
                try writeInvalidRequest(writer, "action must be a string");
                return .bad_request;
            };
        }
        if (object.get("tab") != null) {
            tab = getString(object, "tab") orelse {
                try writeInvalidRequest(writer, "tab must be a string");
                return .bad_request;
            };
        }
        if (object.get("url") != null) {
            url = getString(object, "url") orelse {
                try writeInvalidRequest(writer, "url must be a string");
                return .bad_request;
            };
        }
        if (object.get("label") != null) {
            label = getString(object, "label") orelse {
                try writeInvalidRequest(writer, "label must be a string");
                return .bad_request;
            };
        }
    }

    if (std.mem.eql(u8, action, "list")) {
        if (tab != null or url != null or label != null) {
            try writeInvalidRequest(writer, "list does not accept tab, url, or label");
            return .bad_request;
        }
        return runSimple(allocator, &.{ "tab", "list" }, writer);
    }
    if (std.mem.eql(u8, action, "new")) {
        if (tab != null) {
            try writeInvalidRequest(writer, "new does not accept tab");
            return .bad_request;
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try args.appendSlice(allocator, &.{ "tab", "new" });
        if (label) |value| {
            if (value.len == 0) {
                try writeInvalidRequest(writer, "label must not be empty");
                return .bad_request;
            }
            try args.appendSlice(allocator, &.{ "--label", value });
        }
        if (url) |value| {
            if (value.len == 0) {
                try writeInvalidRequest(writer, "url must not be empty");
                return .bad_request;
            }
            try args.append(allocator, value);
        }
        return runSimple(allocator, args.items, writer);
    }
    if (std.mem.eql(u8, action, "switch")) {
        if (url != null or label != null) {
            try writeInvalidRequest(writer, "switch only accepts tab");
            return .bad_request;
        }
        const target = tab orelse {
            try writeInvalidRequest(writer, "switch requires tab");
            return .bad_request;
        };
        if (target.len == 0) {
            try writeInvalidRequest(writer, "tab must not be empty");
            return .bad_request;
        }
        return runSimple(allocator, &.{ "tab", target }, writer);
    }
    if (std.mem.eql(u8, action, "close")) {
        if (url != null or label != null) {
            try writeInvalidRequest(writer, "close only accepts optional tab");
            return .bad_request;
        }
        if (tab) |target| {
            if (target.len == 0) {
                try writeInvalidRequest(writer, "tab must not be empty");
                return .bad_request;
            }
            return runSimple(allocator, &.{ "tab", "close", target }, writer);
        }
        return runSimple(allocator, &.{ "tab", "close" }, writer);
    }

    try writeInvalidRequest(writer, "action must be list, new, switch, or close");
    return .bad_request;
}

fn browserWait(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const state = try parseRequiredString(arguments, "state", "browser_wait", writer) orelse return .bad_request;
    if (!std.mem.eql(u8, state, "load") and
        !std.mem.eql(u8, state, "domcontentloaded") and
        !std.mem.eql(u8, state, "networkidle"))
    {
        try writeInvalidRequest(writer, "state must be load, domcontentloaded, or networkidle");
        return .bad_request;
    }
    return runSimple(allocator, &.{ "wait", "--load", state }, writer);
}

fn browserGet(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    const what = try parseRequiredString(arguments, "what", "browser_get", writer) orelse return .bad_request;
    if (!std.mem.eql(u8, what, "url") and !std.mem.eql(u8, what, "title")) {
        try writeInvalidRequest(writer, "what must be url or title");
        return .bad_request;
    }
    return runSimple(allocator, &.{ "get", what }, writer);
}

fn browserScreenshot(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    var path: ?[]const u8 = null;
    var full = false;
    if (arguments) |value| {
        const object = switch (value) {
            .object => |object| object,
            else => {
                try writeInvalidRequest(writer, "arguments must be an object");
                return .bad_request;
            },
        };
        if (!hasOnlyFields(object, &.{ "path", "full" })) {
            try writeInvalidRequest(writer, "Invalid browser_screenshot arguments");
            return .bad_request;
        }
        if (object.get("path") != null) {
            path = getString(object, "path") orelse {
                try writeInvalidRequest(writer, "path must be a string");
                return .bad_request;
            };
            if (path.?.len == 0) {
                try writeInvalidRequest(writer, "path must not be empty");
                return .bad_request;
            }
        }
        full = try optionalBool(object, "full", false, writer) orelse return .bad_request;
    }

    if (path) |output_path| {
        if (full) return runSimple(allocator, &.{ "screenshot", output_path, "--full" }, writer);
        return runSimple(allocator, &.{ "screenshot", output_path }, writer);
    }
    if (full) return runSimple(allocator, &.{ "screenshot", "--full" }, writer);
    return runSimple(allocator, &.{"screenshot"}, writer);
}

fn browserTakeover(arguments: ?std.json.Value, writer: *std.Io.Writer) !Outcome {
    const owner_text = try parseRequiredString(arguments, "owner", "browser_takeover", writer) orelse return .bad_request;
    const owner: browser.Owner = if (std.mem.eql(u8, owner_text, "human"))
        .human
    else if (std.mem.eql(u8, owner_text, "agent"))
        .agent
    else {
        try writeInvalidRequest(writer, "owner must be human or agent");
        return .bad_request;
    };

    const status = browser.takeover(owner) catch |err| {
        try writeBrowserFailure(writer, err);
        return .ok;
    };
    try writeSuccess(writer, .{
        .browser = status,
        .snapshotRequired = owner == .agent,
    }, false);
    return .ok;
}

fn browserClose(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    writer: *std.Io.Writer,
) !Outcome {
    if (!try requireNoArguments(arguments, writer)) return .bad_request;
    const result = browser.close(allocator) catch |err| {
        try writeBrowserFailure(writer, err);
        return .ok;
    };
    defer result.deinit(allocator);
    return writeEngineResult(allocator, result, writer);
}

fn runSimple(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !Outcome {
    const result = browser.command(allocator, args) catch |err| {
        try writeBrowserFailure(writer, err);
        return .ok;
    };
    defer result.deinit(allocator);
    return writeEngineResult(allocator, result, writer);
}

fn writeEngineResult(
    allocator: std.mem.Allocator,
    result: browser.CommandResult,
    writer: *std.Io.Writer,
) !Outcome {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch {
        const message = if (result.stderr.len > 0) result.stderr else "agent-browser returned invalid JSON";
        try writeFailure(writer, "AgentBrowserInvalidResponse", message);
        return .ok;
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => {
            try writeFailure(writer, "AgentBrowserInvalidResponse", "agent-browser response was not an object");
            return .ok;
        },
    };
    const success = if (object.get("success")) |value| switch (value) {
        .bool => |flag| flag,
        else => false,
    } else false;

    if (!success) {
        const code = if (object.get("type")) |value| switch (value) {
            .string => |text| text,
            else => "AgentBrowserError",
        } else "AgentBrowserError";
        const message = if (object.get("error")) |value| switch (value) {
            .string => |text| text,
            else => if (result.stderr.len > 0) result.stderr else "agent-browser command failed",
        } else if (result.stderr.len > 0) result.stderr else "agent-browser command failed";
        try writeFailure(writer, code, message);
        return .ok;
    }

    const data: std.json.Value = object.get("data") orelse .null;
    try writeSuccess(writer, .{
        .browser = browser.status(),
        .data = data,
    }, false);
    return .ok;
}

fn writeBrowserFailure(writer: *std.Io.Writer, err: anyerror) !void {
    const pair = switch (err) {
        error.BrowserUnavailable => .{ "BrowserUnavailable", "agent-browser is not installed or its native executable could not be found" },
        error.BrowserAlreadyActive => .{ "BrowserAlreadyActive", "A zshell browser session is already active" },
        error.BrowserNotActive => .{ "BrowserNotActive", "No zshell browser session is active" },
        error.BrowserHumanControlActive => .{ "BrowserHumanControlActive", "The user currently owns browser control. Wait until the user explicitly returns control to the agent." },
        error.BrowserMustBeVisible => .{ "BrowserMustBeVisible", "Human takeover requires a visible browser session. Start the browser with visible=true." },
        error.BrowserSessionLost => .{ "BrowserSessionLost", "The browser session disappeared while control was away. Start a new browser session; no stale refs will be reused." },
        error.InvalidBrowserEncryptionKey => .{ "InvalidBrowserEncryptionKey", "The persistent browser encryption key is missing or invalid." },
        error.InvalidProfileName => .{ "InvalidProfileName", "The browser profile name is invalid" },
        error.ProfileRequired => .{ "ProfileRequired", "chrome_profile mode requires a Chrome profile name" },
        error.FileNotFound => .{ "BrowserExecutableNotFound", "A required browser executable could not be started" },
        else => .{ @errorName(err), "Browser operation failed" },
    };
    try writeFailure(writer, pair[0], pair[1]);
}

const NormalizedRef = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

fn normalizeRef(
    allocator: std.mem.Allocator,
    raw: []const u8,
    writer: *std.Io.Writer,
) !?NormalizedRef {
    const value = if (std.mem.startsWith(u8, raw, "@")) raw[1..] else raw;
    if (value.len < 2 or value[0] != 'e') {
        try writeInvalidRequest(writer, "ref must look like e1 or @e1");
        return null;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) {
            try writeInvalidRequest(writer, "ref must look like e1 or @e1");
            return null;
        }
    }
    if (std.mem.startsWith(u8, raw, "@")) return .{ .value = raw };
    const owned = try std.fmt.allocPrint(allocator, "@{s}", .{raw});
    return .{ .value = owned, .owned = owned };
}

const RefStringPair = struct {
    ref: []const u8,
    value: []const u8,
    owned_ref: ?[]u8,
};

fn parseRefAndString(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    value_field: []const u8,
    operation: []const u8,
    writer: *std.Io.Writer,
) !?RefStringPair {
    const args = arguments orelse {
        try writeInvalidRequest(writer, "browser operation requires arguments");
        return null;
    };
    const object = switch (args) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return null;
        },
    };
    if (!hasOnlyFields(object, &.{ "ref", value_field })) {
        _ = operation;
        try writeInvalidRequest(writer, "Invalid browser arguments");
        return null;
    }
    const ref_text = getString(object, "ref") orelse {
        try writeInvalidRequest(writer, "ref must be a string");
        return null;
    };
    const normalized = try normalizeRef(allocator, ref_text, writer) orelse return null;
    errdefer if (normalized.owned) |owned| allocator.free(owned);
    const string_value = getString(object, value_field) orelse {
        try writeInvalidRequest(writer, "browser value must be a string");
        return null;
    };
    return .{
        .ref = normalized.value,
        .value = string_value,
        .owned_ref = normalized.owned,
    };
}

fn parseStartInput(arguments: ?std.json.Value, writer: *std.Io.Writer) !?browser.StartInput {
    const value = arguments orelse return .{};
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return null;
        },
    };
    if (!hasOnlyFields(object, &.{ "mode", "visible", "profile" })) {
        try writeInvalidRequest(writer, "Invalid browser_start arguments");
        return null;
    }

    const mode_text = if (object.get("mode") != null)
        getString(object, "mode") orelse {
            try writeInvalidRequest(writer, "mode must be a string");
            return null;
        }
    else
        "temporary";
    const mode: browser.Mode = if (std.mem.eql(u8, mode_text, "temporary"))
        .temporary
    else if (std.mem.eql(u8, mode_text, "persistent"))
        .persistent
    else if (std.mem.eql(u8, mode_text, "chrome_profile"))
        .chrome_profile
    else {
        try writeInvalidRequest(writer, "mode must be temporary, persistent, or chrome_profile");
        return null;
    };

    const visible = try optionalBool(object, "visible", false, writer) orelse return null;
    const profile = if (object.get("profile") != null)
        getString(object, "profile") orelse {
            try writeInvalidRequest(writer, "profile must be a string");
            return null;
        }
    else
        null;

    return .{ .mode = mode, .visible = visible, .profile = profile };
}

fn parseRequiredString(
    arguments: ?std.json.Value,
    field: []const u8,
    operation: []const u8,
    writer: *std.Io.Writer,
) !?[]const u8 {
    const value = arguments orelse {
        _ = operation;
        try writeInvalidRequest(writer, "browser operation requires arguments");
        return null;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return null;
        },
    };
    if (!hasOnlyFields(object, &.{field})) {
        try writeInvalidRequest(writer, "Invalid browser arguments");
        return null;
    }
    const text = getString(object, field) orelse {
        try writeInvalidRequest(writer, "browser argument must be a string");
        return null;
    };
    if (text.len == 0) {
        try writeInvalidRequest(writer, "browser argument must not be empty");
        return null;
    }
    return text;
}

fn parseOptionalBoolObject(
    arguments: ?std.json.Value,
    field: []const u8,
    default_value: bool,
    operation: []const u8,
    writer: *std.Io.Writer,
) !?bool {
    const value = arguments orelse return default_value;
    const object = switch (value) {
        .object => |object| object,
        else => {
            try writeInvalidRequest(writer, "arguments must be an object");
            return null;
        },
    };
    if (!hasOnlyFields(object, &.{field})) {
        _ = operation;
        try writeInvalidRequest(writer, "Invalid browser arguments");
        return null;
    }
    return optionalBool(object, field, default_value, writer);
}

fn optionalBool(object: anytype, field: []const u8, default_value: bool, writer: *std.Io.Writer) !?bool {
    const value = object.get(field) orelse return default_value;
    return switch (value) {
        .bool => |flag| flag,
        else => {
            try writeInvalidRequest(writer, "browser boolean argument must be a boolean");
            return null;
        },
    };
}

fn hasOnlyFields(object: anytype, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn getString(object: anytype, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn requireNoArguments(arguments: ?std.json.Value, writer: *std.Io.Writer) !bool {
    const value = arguments orelse return true;
    switch (value) {
        .object => |object| if (object.count() == 0) return true,
        else => {},
    }
    try writeInvalidRequest(writer, "operation accepts no arguments");
    return false;
}

fn writeSuccess(writer: *std.Io.Writer, result: anytype, is_error: bool) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = true,
        .result = result,
        .isError = is_error,
    }, .{ .emit_null_optional_fields = false })});
}

fn writeFailure(writer: *std.Io.Writer, code: []const u8, message: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .isError = true,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{})});
}

fn writeInvalidRequest(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(.{
        .ok = false,
        .invalidRequest = true,
        .isError = true,
        .@"error" = .{
            .code = "InvalidRequest",
            .message = message,
        },
    }, .{})});
}

test "normalizes refs without shell quoting" {
    const allocator = std.testing.allocator;
    const ref = try normalizeRefForTest(allocator, "e42");
    defer allocator.free(ref);
    try std.testing.expectEqualStrings("@e42", ref);
}

fn normalizeRefForTest(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw, "@")) return allocator.dupe(u8, raw);
    return std.fmt.allocPrint(allocator, "@{s}", .{raw});
}
