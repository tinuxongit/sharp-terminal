//! Claude's browser tools (browser_tools.zon), run on the MCP server's
//! threads. Each reads or drives the panel's page through DevTools calls
//! that browser_remote hands to the UI thread. Ported from Citropy's
//! desktop/browser.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const w32 = @import("win32.zig");
const snapshot_tree = @import("browser_snapshot.zig");
const browser_page = @import("browser_page.zig");
const locator = @import("browser_locator.zig");
const browser_frames = @import("browser_frames.zig");
const claude_session = @import("claude_session.zig");
const pointer = @import("browser_pointer.zig");
const gestures = @import("browser_gestures.zig");
const screenshots = @import("browser_screenshot.zig");
const browser_settings = @import("browser_settings.zig");
const BrowserTab = @import("BrowserTab.zig");
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const Point = browser_page.Point;
const Chat = @import("browser_chats.zig").Chat;
const remote = @import("browser_remote.zig");
const field = json_read.field;
const string = json_read.string;
const boolean = json_read.boolean;
const number = json_read.number;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

pub const Data = struct {
    server_name: []const u8,
    instructions: []const u8,
    load_upfront: bool,
    tools: []const Tool,
};

pub const data: Data = @import("browser_tools.zon");

const Name = enum { browser_open, browser_tabs, browser_close, browser_snapshot, browser_logs, browser_action };

comptime {
    for (data.tools) |tool| {
        if (std.meta.stringToEnum(Name, tool.name) == null)
            @compileError("browser_tools.zon: no handler for " ++ tool.name);
    }
}

const Action = enum { navigate, back, forward, reload, stop, expand, click, hover, type, press, scroll, swipe, select, upload, wait, evaluate, dialog, emulate, resize };

/// What a tool answers: text, and a JPEG (base64) when it took a picture.
pub const Output = struct {
    is_error: bool = false,
    text: []const u8,
    image: ?[]const u8 = null,
};

/// Run tool `name`. The output lives in `arena`.
pub fn run(arena: Allocator, chat: *const Chat, name: []const u8, args: Value) Output {
    const tool = std.meta.stringToEnum(Name, name) orelse return .{ .is_error = true, .text = "Unknown tool" };
    var page: Page = .{ .arena = arena, .chat = chat };
    defer if (remote.call(chat, .idle, 5_000)) |answer| answer.free() else |_| {};
    return switch (tool) {
        .browser_open => open(&page, args),
        .browser_tabs => listTabs(&page),
        .browser_close => close(&page, args),
        .browser_snapshot => snapshot(&page, args),
        .browser_logs => logs(&page, args),
        .browser_action => action(&page, args),
    } catch |err| .{ .is_error = true, .text = page.failure orelse @errorName(err) };
}

fn open(page: *Page, args: Value) !Output {
    const url = if (string(args, "url")) |typed| try page.webAddress(typed) else "";
    page.tab = try page.parseId(try page.remoteCall(.{ .open = .{ .url = url } }, 5_000));
    try page.waitReady();
    if (url.len > 0) page.settle(true);
    var out: std.Io.Writer.Allocating = .init(page.arena);
    try out.writer.print("Tab {d}\n", .{page.tab});
    try page.header(&out.writer);
    return .{ .text = out.written() };
}

fn listTabs(page: *Page) !Output {
    const tabs = try page.tabs();
    if (tabs.len == 0) return .{ .text = "No tabs are open. browser_open opens one." };
    var out: std.Io.Writer.Allocating = .init(page.arena);
    for (tabs) |t| try out.writer.print("Tab {d}: {s} — {s}{s}\n", .{ t.id, t.title, t.url, if (t.active) " (active)" else "" });
    return .{ .text = out.written() };
}

fn close(page: *Page, args: Value) !Output {
    const id = number(args, "tab") orelse return page.fail("Name the tab to close; browser_tabs lists them.", .{});
    if (id < 1 or id > std.math.maxInt(u32)) return page.fail("There is no such tab. browser_tabs lists them.", .{});
    _ = try page.remoteCall(.{ .close = .{ .tab = @intFromFloat(id) } }, 5_000);
    return .{ .text = try std.fmt.allocPrint(page.arena, "Closed tab {d}.", .{@as(u32, @intFromFloat(id))}) };
}

fn snapshot(page: *Page, args: Value) !Output {
    try page.selectTab(args);
    try page.waitReady();
    var out: std.Io.Writer.Allocating = .init(page.arena);
    try page.header(&out.writer);
    if (boolean(args, "tree") orelse true) {
        const root_ref = try scopeRef(page, args);
        const nodes = try browser_frames.tree(page);
        var tree: std.Io.Writer.Allocating = .init(page.arena);
        try snapshot_tree.write(page.arena, nodes.items, root_ref, &tree.writer);
        const text = tree.written();
        try out.writer.writeAll("\n\n");
        if (text.len <= snapshot_tree.max_length) {
            try out.writer.writeAll(text);
        } else {
            // Cut at a line so no element is half shown.
            const cut = std.mem.lastIndexOfScalar(u8, text[0..snapshot_tree.max_length], '\n') orelse snapshot_tree.max_length;
            try out.writer.print("{s}\n… truncated. Snapshot a ref or selector to see the rest.", .{text[0..cut]});
        }
    }
    const image = if (boolean(args, "screenshot") orelse false) try screenshots.take(page, try scopeNode(page, args), boolean(args, "fullPage") orelse false) else null;
    return .{ .text = out.written(), .image = image };
}

fn scopeNode(page: *Page, args: Value) !?locator.Node {
    if (string(args, "ref")) |ref| return try locator.fromRef(page, ref);
    if (string(args, "selector") == null) return null;
    return locator.find(page, args);
}

fn scopeRef(page: *Page, args: Value) !?[]const u8 {
    if (string(args, "ref")) |ref| {
        _ = try locator.fromRef(page, ref);
        return ref;
    }
    const selector = string(args, "selector") orelse return null;
    var only: std.json.ObjectMap = .empty;
    try only.put(page.arena, "selector", .{ .string = selector });
    const node = (try locator.find(page, .{ .object = only })) orelse return null;
    const described = try page.devtools("DOM.describeNode", node.params());
    const id = number(field(described, "node") orelse return null, "backendNodeId") orelse return null;
    return try std.fmt.allocPrint(page.arena, "{d}", .{@as(i64, @intFromFloat(id))});
}

fn logs(page: *Page, args: Value) !Output {
    try page.selectTab(args);
    const text = try page.remoteCall(.{ .logs = .{ .tab = page.tab, .since_ms = 0, .clear = boolean(args, "clear") orelse true } }, 5_000);
    return .{ .text = if (text.len == 0) "No new messages." else text };
}

fn action(page: *Page, args: Value) !Output {
    try page.selectTab(args);
    try page.waitReady();
    const name = string(args, "action") orelse return page.fail("Choose an action.", .{});
    const act = std.meta.stringToEnum(Action, name) orelse return page.fail("Unknown browser action: {s}", .{name});
    if (act != .dialog) {
        if (try page.dialog()) |d| return page.fail("Answer the page's {s} dialog first: {s}", .{ d.kind, d.message });
    }
    const since = w32.GetTickCount64();
    var newest: u32 = 0;
    for (try page.tabs()) |t| newest = @max(newest, t.id);
    const result = perform(page, args, act) catch |err| switch (err) {
        error.Dialog => null,
        else => return err,
    };

    var out: std.Io.Writer.Allocating = .init(page.arena);
    for (try page.tabs()) |t| if (t.id == page.tab) try out.writer.print("{s}\n{s}\n", .{ t.title, t.url });
    if (result) |r| try out.writer.print("\nResult: {s}\n", .{r});
    if (try page.dialog()) |d| try out.writer.print("\nA {s} dialog is open: {s}\nAnswer it with browser_action dialog (accept true or false, and text for a prompt).\n", .{ d.kind, d.message });
    const logged = try page.remoteCall(.{ .logs = .{ .tab = page.tab, .since_ms = since, .clear = false } }, 5_000);
    if (logged.len > 0) try out.writer.print("\nThe page logged:\n{s}", .{logged});
    // A link or script may have opened tabs.
    for (try page.tabs()) |t| if (t.id > newest) try out.writer.print("\nIt opened tab {d}: {s}\n", .{ t.id, t.url });
    return .{ .text = out.written() };
}

fn perform(page: *Page, args: Value, act: Action) !?[]const u8 {
    switch (act) {
        .navigate => try page.navigate(string(args, "url") orelse return page.fail("navigate needs a url.", .{})),
        .back, .forward, .reload, .stop => {
            _ = try page.remoteCall(.{ .history = .{ .tab = page.tab, .step = switch (act) {
                .back => .back,
                .forward => .forward,
                .stop => .stop,
                else => .reload,
            } } }, 5_000);
            if (act != .stop) page.settle(false);
        },
        .expand => _ = try page.remoteCall(.{ .expand = .{ .on = boolean(args, "expanded") orelse true } }, 5_000),
        .click => {
            const aim = try locator.aim(page, args, "click");
            try showPress(page, aim);
            if (page.devtools("Page.setInterceptFileChooserDialog", .{ .enabled = true })) |_| {} else |err| if (err == error.Dialog) return err;
            defer _ = page.devtools("Page.setInterceptFileChooserDialog", .{ .enabled = false }) catch null;
            try page.click(aim.at);
            pointer.rest(page);
            page.settle(false);
        },
        .hover => {
            const aim = try locator.aim(page, args, "hover");
            try pointer.moveTo(page, aim.at);
            try page.mouse("mouseMoved", aim.at, "none");
        },
        .type => {
            const text = string(args, "text") orelse return page.fail("type needs text.", .{});
            if (try locator.find(page, args)) |node| {
                const b = try locator.elementBox(page, node, .content);
                try showPress(page, .{ .at = locator.center(b), .box = b });
                try page.click(locator.center(b));
                pointer.rest(page);
                _ = try locator.call(page, node, locator.select_contents, null);
            }
            _ = try page.devtools("Input.insertText", .{ .text = text });
            page.settle(false);
        },
        .press => {
            try page.press(string(args, "key") orelse return page.fail("press needs a key.", .{}));
            page.settle(false);
        },
        .scroll => {
            const dx = number(args, "x") orelse return page.fail("scroll needs x and y distances.", .{});
            const dy = number(args, "y") orelse return page.fail("scroll needs x and y distances.", .{});
            const point = if (try locator.find(page, args)) |node| locator.center(try locator.elementBox(page, node, .content)) else middle: {
                const info = try page.info();
                break :middle Point{ .x = info.width / 2, .y = info.height / 2 };
            };
            _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mouseWheel", .x = point.x, .y = point.y, .deltaX = dx, .deltaY = dy });
        },
        .swipe => {
            const result = try gestures.swipe(page, args);
            page.settle(false);
            return result;
        },
        .select => {
            const option = string(args, "option") orelse return page.fail("select needs the option's value or visible text.", .{});
            const node = (try locator.find(page, args)) orelse return page.fail("Choose the dropdown by ref, selector or role.", .{});
            try showNodePress(page, node);
            const chosen = try locator.call(page, node, locator.choose_option, option);
            page.settle(false);
            return try std.fmt.allocPrint(page.arena, "Selected {s}", .{if (chosen == .string) chosen.string else option});
        },
        .upload => {
            const node = (try locator.find(page, args)) orelse return page.fail("Choose the file input by ref, selector or role.", .{});
            const files = try uploadPaths(page, args);
            try showNodePress(page, node);
            _ = try page.devtoolsIn(node.session, "DOM.setFileInputFiles", .{ .files = files, .backendNodeId = node.backend, .objectId = node.object });
            page.settle(false);
            return try std.fmt.allocPrint(page.arena, "Chose {d} file{s}", .{ files.len, if (files.len == 1) "" else "s" });
        },
        .wait => try page.wait(args),
        .evaluate => {
            const value = try page.evaluate(string(args, "expression") orelse return page.fail("evaluate needs an expression.", .{}));
            return try std.json.Stringify.valueAlloc(page.arena, value, .{});
        },
        .dialog => {
            _ = try page.remoteCall(.{ .answer = .{ .tab = page.tab, .accept = boolean(args, "accept") orelse true, .text = string(args, "text") orelse "" } }, 5_000);
            page.settle(false);
        },
        .emulate => {
            const color = if (string(args, "colorScheme")) |c| std.meta.stringToEnum(BrowserTab.ColorScheme, c) orelse
                return page.fail("colorScheme is light, dark or none.", .{}) else null;
            const motion = if (string(args, "reducedMotion")) |m| std.meta.stringToEnum(BrowserTab.Motion, m) orelse
                return page.fail("reducedMotion is reduce, no-preference or none.", .{}) else null;
            if (color == null and motion == null) return page.fail("emulate needs colorScheme or reducedMotion.", .{});
            _ = try page.remoteCall(.{ .media = .{ .tab = page.tab, .color = color, .motion = motion } }, 5_000);
        },
        .resize => {
            const limits = browser_settings.data.viewport_limits;
            const width = number(args, "width") orelse return page.fail("resize needs width and height.", .{});
            const height = number(args, "height") orelse return page.fail("resize needs width and height.", .{});
            if (width < @as(f64, @floatFromInt(limits.min_width)) or width > @as(f64, @floatFromInt(limits.max_width)) or
                height < @as(f64, @floatFromInt(limits.min_height)) or height > @as(f64, @floatFromInt(limits.max_height)))
                return page.fail("Use a width from {d} to {d} and a height from {d} to {d}.", .{ limits.min_width, limits.max_width, limits.min_height, limits.max_height });
            const mobile = boolean(args, "mobile");
            _ = try page.remoteCall(.{ .viewport = .{ .tab = page.tab, .width = @intFromFloat(width), .height = @intFromFloat(height), .mobile = mobile } }, 5_000);
            page.settle(false);
        },
    }
    return null;
}

fn showPress(page: *Page, aim: locator.Aim) !void {
    try pointer.moveTo(page, aim.at);
    try pointer.press(page, aim.at, aim.box);
}

fn showNodePress(page: *Page, node: locator.Node) !void {
    const b = try locator.elementBox(page, node, .content);
    try showPress(page, .{ .at = locator.center(b), .box = b });
    pointer.rest(page);
}

fn uploadPaths(page: *Page, args: Value) ![]const []const u8 {
    const list = field(args, "paths") orelse return page.fail("upload needs paths.", .{});
    if (list != .array or list.array.items.len == 0) return page.fail("upload needs paths.", .{});
    const session = claude_session.read(page.chat.claude) orelse
        return page.fail("Sharp couldn't tell which folder this conversation works in, so it can't upload files.", .{});
    const root = try fullPath(page, session.folder());
    var files: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        if (item != .string or item.string.len == 0) return page.fail("Give each file as a path.", .{});
        const absolute = (item.string.len > 2 and item.string[1] == ':') or std.mem.startsWith(u8, item.string, "\\\\");
        const joined = if (absolute) item.string else try std.fmt.allocPrint(page.arena, "{s}\\{s}", .{ root, item.string });
        const full = try fullPath(page, joined);
        const inside = full.len > root.len and std.ascii.startsWithIgnoreCase(full, root) and (full[root.len] == '\\' or root[root.len - 1] == '\\');
        if (!inside) return page.fail("Only files inside this conversation's folder ({s}) can be uploaded: {s}", .{ root, item.string });
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(page.arena, full);
        const attributes = w32.GetFileAttributesW(wide);
        if (attributes == w32.INVALID_FILE_ATTRIBUTES) return page.fail("File not found: {s}", .{item.string});
        if (attributes & w32.FILE_ATTRIBUTE_DIRECTORY != 0) return page.fail("That is a folder, not a file: {s}", .{item.string});
        try files.append(page.arena, full);
    }
    return files.items;
}

fn fullPath(page: *Page, path: []const u8) ![]const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(page.arena, path);
    var buf: [1024]u16 = undefined;
    const len = w32.GetFullPathNameW(wide, buf.len, &buf, null);
    if (len == 0 or len >= buf.len) return page.fail("That path is too long: {s}", .{path});
    var trimmed = buf[0..len];
    while (trimmed.len > 3 and trimmed[trimmed.len - 1] == '\\') trimmed = trimmed[0 .. trimmed.len - 1];
    return std.unicode.utf16LeToUtf8Alloc(page.arena, trimmed);
}
