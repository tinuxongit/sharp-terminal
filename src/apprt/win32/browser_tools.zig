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
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const Point = browser_page.Point;
const no_params = browser_page.no_params;
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

const Action = enum { navigate, back, forward, reload, click, hover, type, press, scroll, wait, evaluate };

/// What a tool answers: text, and a JPEG (base64) when it took a picture.
pub const Output = struct {
    is_error: bool = false,
    text: []const u8,
    image: ?[]const u8 = null,
};

/// Run tool `name`. The output lives in `arena`.
pub fn run(arena: Allocator, name: []const u8, args: Value) Output {
    const tool = std.meta.stringToEnum(Name, name) orelse return .{ .is_error = true, .text = "Unknown tool" };
    var page: Page = .{ .arena = arena };
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
        const root_ref: ?i64 = if (string(args, "ref")) |ref| try page.parseRef(ref) else null;
        const ax = try page.devtools("Accessibility.getFullAXTree", no_params);
        const nodes = field(ax, "nodes") orelse return page.fail("The page gave no accessibility tree.", .{});
        if (nodes != .array) return page.fail("The page gave no accessibility tree.", .{});
        var tree: std.Io.Writer.Allocating = .init(page.arena);
        try snapshot_tree.write(page.arena, nodes.array.items, root_ref, &tree.writer);
        const text = tree.written();
        try out.writer.writeAll("\n\n");
        if (text.len <= snapshot_tree.max_length) {
            try out.writer.writeAll(text);
        } else {
            // Cut at a line so no element is half shown.
            const cut = std.mem.lastIndexOfScalar(u8, text[0..snapshot_tree.max_length], '\n') orelse snapshot_tree.max_length;
            try out.writer.print("{s}\n… truncated. Snapshot a ref to see the rest.", .{text[0..cut]});
        }
    }
    const image = if (boolean(args, "screenshot") orelse false) try page.screenshot() else null;
    return .{ .text = out.written(), .image = image };
}

fn logs(page: *Page, args: Value) !Output {
    try page.selectTab(args);
    const text = try page.remoteCall(.{ .logs = .{ .tab = page.tab, .since_ms = 0, .clear = boolean(args, "clear") orelse true } }, 5_000);
    return .{ .text = if (text.len == 0) "No new messages." else text };
}

fn action(page: *Page, args: Value) !Output {
    try page.selectTab(args);
    try page.waitReady();
    const since = w32.GetTickCount64();
    var newest: u32 = 0;
    for (try page.tabs()) |t| newest = @max(newest, t.id);
    const name = string(args, "action") orelse return page.fail("Choose an action.", .{});
    const act = std.meta.stringToEnum(Action, name) orelse return page.fail("Unknown browser action: {s}", .{name});
    var result: ?[]const u8 = null;
    switch (act) {
        .navigate => try page.navigate(string(args, "url") orelse return page.fail("navigate needs a url.", .{})),
        .back, .forward, .reload => {
            _ = try page.remoteCall(.{ .history = .{ .tab = page.tab, .step = switch (act) {
                .back => .back,
                .forward => .forward,
                else => .reload,
            } } }, 5_000);
            page.settle(false);
        },
        .click => {
            try page.click(try page.target(args, "click"));
            page.settle(false);
        },
        .hover => try page.mouse("mouseMoved", try page.target(args, "hover"), "none"),
        .type => {
            const text = string(args, "text") orelse return page.fail("type needs text.", .{});
            if (string(args, "ref")) |ref| try page.focusAndSelect(ref);
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
            const point = if (string(args, "ref")) |ref| try page.refPoint(ref) else middle: {
                const info = try page.info();
                break :middle Point{ .x = info.width / 2, .y = info.height / 2 };
            };
            _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mouseWheel", .x = point.x, .y = point.y, .deltaX = dx, .deltaY = dy });
        },
        .wait => try page.wait(args),
        .evaluate => {
            const value = try page.evaluate(string(args, "expression") orelse return page.fail("evaluate needs an expression.", .{}));
            result = try std.json.Stringify.valueAlloc(page.arena, value, .{});
        },
    }

    var out: std.Io.Writer.Allocating = .init(page.arena);
    const info = try page.info();
    try out.writer.print("{s}\n{s}\n", .{ info.title, info.url });
    if (result) |r| try out.writer.print("\nResult: {s}\n", .{r});
    const logged = try page.remoteCall(.{ .logs = .{ .tab = page.tab, .since_ms = since, .clear = false } }, 5_000);
    if (logged.len > 0) try out.writer.print("\nThe page logged:\n{s}", .{logged});
    // A link or script may have opened tabs.
    for (try page.tabs()) |t| if (t.id > newest) try out.writer.print("\nIt opened tab {d}: {s}\n", .{ t.id, t.url });
    return .{ .text = out.written() };
}
