//! Claude's browser tools (browser_tools.zon), run on the MCP server's
//! threads. Each reads or drives the panel's page through DevTools calls
//! that browser_remote hands to the UI thread. Ported from Citropy's
//! desktop/browser, for one page instead of tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const w32 = @import("win32.zig");
const remote = @import("browser_remote.zig");
const snapshot_tree = @import("browser_snapshot.zig");
const BrowserPanel = @import("BrowserPanel.zig");

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

const Name = enum { browser_open, browser_snapshot, browser_logs, browser_action };

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
        .browser_snapshot => snapshot(&page, args),
        .browser_logs => logs(&page, args),
        .browser_action => action(&page, args),
    } catch |err| .{ .is_error = true, .text = page.failure orelse @errorName(err) };
}

fn open(page: *Page, args: Value) !Output {
    _ = try page.remoteCall(.open, 5_000);
    try page.waitReady();
    if (string(args, "url")) |url| try page.navigate(url);
    var out: std.Io.Writer.Allocating = .init(page.arena);
    try page.header(&out.writer);
    return .{ .text = out.written() };
}

fn snapshot(page: *Page, args: Value) !Output {
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
    const text = try page.remoteCall(.{ .logs = .{ .since_ms = 0, .clear = boolean(args, "clear") orelse true } }, 5_000);
    return .{ .text = if (text.len == 0) "No new messages." else text };
}

fn action(page: *Page, args: Value) !Output {
    try page.waitReady();
    const since = w32.GetTickCount64();
    const name = string(args, "action") orelse return page.fail("Choose an action.", .{});
    const act = std.meta.stringToEnum(Action, name) orelse return page.fail("Unknown browser action: {s}", .{name});
    var result: ?[]const u8 = null;
    switch (act) {
        .navigate => try page.navigate(string(args, "url") orelse return page.fail("navigate needs a url.", .{})),
        .back, .forward, .reload => {
            _ = try page.remoteCall(switch (act) {
                .back => .back,
                .forward => .forward,
                else => .reload,
            }, 5_000);
            page.settle();
        },
        .click => {
            try page.click(try page.target(args, "click"));
            page.settle();
        },
        .hover => try page.mouse("mouseMoved", try page.target(args, "hover"), "none"),
        .type => {
            const text = string(args, "text") orelse return page.fail("type needs text.", .{});
            if (string(args, "ref")) |ref| try page.focusAndSelect(ref);
            _ = try page.devtools("Input.insertText", .{ .text = text });
            page.settle();
        },
        .press => {
            try page.press(string(args, "key") orelse return page.fail("press needs a key.", .{}));
            page.settle();
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
    const logged = try page.remoteCall(.{ .logs = .{ .since_ms = since, .clear = false } }, 5_000);
    if (logged.len > 0) try out.writer.print("\nThe page logged:\n{s}", .{logged});
    return .{ .text = out.written() };
}

const Point = struct { x: f64, y: f64 };

/// An empty struct writes as {}; an empty tuple (.{}) would write [].
const no_params = struct {}{};

const PageInfo = struct {
    title: []const u8,
    url: []const u8,
    width: f64,
    height: f64,
    scroll_x: f64,
    scroll_y: f64,
    pixel_ratio: f64,
};

/// One tool call's view of the page, with why it failed in words for
/// Claude.
const Page = struct {
    arena: Allocator,
    failure: ?[]const u8 = null,

    fn fail(self: *Page, comptime fmt: []const u8, args: anytype) error{ Failed, OutOfMemory } {
        self.failure = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.Failed;
    }

    fn remoteCall(self: *Page, op: remote.Op, timeout_ms: u32) ![]const u8 {
        const answer = remote.call(op, timeout_ms) catch |err| return switch (err) {
            error.Unavailable => self.fail("Sharp couldn't reach its browser.", .{}),
            error.TimedOut => self.fail("The browser didn't answer in time.", .{}),
        };
        defer answer.free();
        const text = try self.arena.dupe(u8, answer.text);
        if (!answer.ok) return self.fail("{s}", .{if (text.len > 0) text else "The browser couldn't do that."});
        return text;
    }

    /// Call a DevTools method; its error message becomes the failure.
    fn devtools(self: *Page, method: []const u8, params: anytype) !Value {
        const json = try std.json.Stringify.valueAlloc(self.arena, params, .{});
        const answer = remote.call(.{ .devtools = .{ .method = method, .params = json } }, 30_000) catch |err| return switch (err) {
            error.Unavailable => self.fail("Sharp couldn't reach its browser.", .{}),
            error.TimedOut => self.fail("The page didn't answer {s} in time.", .{method}),
        };
        defer answer.free();
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, answer.text, .{ .allocate = .alloc_always }) catch null;
        if (!answer.ok) {
            const err = if (parsed) |p| field(p, "error") orelse p else null;
            const message = if (err) |e| string(e, "message") else null;
            return self.fail("{s} failed: {s}", .{ method, message orelse answer.text });
        }
        return parsed orelse self.fail("{s} answered something unreadable.", .{method});
    }

    /// Run JavaScript in the page and return its value as JSON.
    fn evaluate(self: *Page, expression: []const u8) !Value {
        const answer = try self.devtools("Runtime.evaluate", .{ .expression = expression, .returnByValue = true, .awaitPromise = true });
        if (field(answer, "exceptionDetails")) |details| {
            const description = if (field(details, "exception")) |e| string(e, "description") else null;
            return self.fail("{s}", .{description orelse string(details, "text") orelse "The script threw."});
        }
        const result = field(answer, "result") orelse return .null;
        return field(result, "value") orelse .null;
    }

    /// Wait until the panel's page exists; it starts when the panel opens.
    fn waitReady(self: *Page) !void {
        var waited: u32 = 0;
        while (waited < 20_000) : (waited += 200) {
            const answer = remote.call(.ready, 5_000) catch return self.fail("Sharp couldn't reach its browser.", .{});
            defer answer.free();
            if (answer.ok) return;
            if (answer.text.len > 0) return self.fail("{s}", .{try self.arena.dupe(u8, answer.text)});
            w32.Sleep(200);
        }
        return self.fail("The browser is still starting. Try again in a moment.", .{});
    }

    /// Give a navigation an action may have started time to load.
    fn settle(self: *Page) void {
        w32.Sleep(300);
        var waited: u32 = 0;
        while (waited < 10_000) : (waited += 250) {
            const state = self.evaluate("document.readyState") catch {
                w32.Sleep(250);
                continue;
            };
            if (state == .string and std.mem.eql(u8, state.string, "complete")) break;
            w32.Sleep(250);
        }
        // Calls that failed mid-navigation are not the action's failure.
        self.failure = null;
    }

    fn navigate(self: *Page, typed: []const u8) !void {
        var buf: [2048]u8 = undefined;
        const url = BrowserPanel.addressFor(std.mem.trim(u8, typed, " \t"), &buf) orelse return self.fail("Give an address to open.", .{});
        const answer = try self.devtools("Page.navigate", .{ .url = url });
        if (string(answer, "errorText")) |err| if (err.len > 0) return self.fail("Couldn't open {s}: {s}", .{ url, err });
        self.settle();
    }

    fn info(self: *Page) !PageInfo {
        const v = try self.evaluate("[document.title, location.href, innerWidth, innerHeight, scrollX, scrollY, devicePixelRatio]");
        if (v != .array or v.array.items.len != 7) return self.fail("Couldn't read the page.", .{});
        const items = v.array.items;
        return .{
            .title = if (items[0] == .string) items[0].string else "",
            .url = if (items[1] == .string) items[1].string else "",
            .width = asNumber(items[2]) orelse 0,
            .height = asNumber(items[3]) orelse 0,
            .scroll_x = asNumber(items[4]) orelse 0,
            .scroll_y = asNumber(items[5]) orelse 0,
            .pixel_ratio = asNumber(items[6]) orelse 1,
        };
    }

    /// Title, address and viewport, which every snapshot starts with.
    fn header(self: *Page, w: *std.Io.Writer) !void {
        const i = try self.info();
        try w.print("{s}\n{s}\nViewport: {d} × {d}. Screenshot coordinates use these dimensions. Use [ref=N] values with browser_action ref.", .{ i.title, i.url, i.width, i.height });
        const unread = try self.remoteCall(.{ .logs = .{ .since_ms = 0, .clear = false } }, 5_000);
        const errors = std.mem.count(u8, unread, "[error]");
        if (errors > 0) try w.print(" {d} unread error{s} in browser_logs.", .{ errors, if (errors == 1) "" else "s" });
    }

    /// The viewport as a JPEG, in CSS pixels so its coordinates are the
    /// ones click takes.
    fn screenshot(self: *Page) ![]const u8 {
        const i = try self.info();
        const answer = try self.devtools("Page.captureScreenshot", .{
            .format = "jpeg",
            .quality = 80,
            .clip = .{ .x = i.scroll_x, .y = i.scroll_y, .width = i.width, .height = i.height, .scale = 1 / @max(i.pixel_ratio, 0.1) },
        });
        return string(answer, "data") orelse self.fail("The page gave no picture.", .{});
    }

    fn parseRef(self: *Page, ref: []const u8) !i64 {
        return std.fmt.parseInt(i64, ref, 10) catch self.fail("Use a ref from the latest snapshot.", .{});
    }

    /// The middle of the element `ref` names, scrolled into view.
    fn refPoint(self: *Page, ref: []const u8) !Point {
        const id = try self.parseRef(ref);
        _ = self.devtools("DOM.scrollIntoViewIfNeeded", .{ .backendNodeId = id }) catch
            return self.fail("That element is no longer on the page. Take a new snapshot for current refs.", .{});
        const box = try self.devtools("DOM.getBoxModel", .{ .backendNodeId = id });
        const model = field(box, "model") orelse return self.fail("That element has no box on the page.", .{});
        const quad = field(model, "content") orelse return self.fail("That element has no box on the page.", .{});
        if (quad != .array or quad.array.items.len != 8) return self.fail("That element has no box on the page.", .{});
        var sum: Point = .{ .x = 0, .y = 0 };
        for (0..4) |c| {
            sum.x += asNumber(quad.array.items[2 * c]) orelse 0;
            sum.y += asNumber(quad.array.items[2 * c + 1]) orelse 0;
        }
        return .{ .x = sum.x / 4, .y = sum.y / 4 };
    }

    fn target(self: *Page, args: Value, verb: []const u8) !Point {
        if (string(args, "ref")) |ref| return self.refPoint(ref);
        const x = number(args, "x") orelse return self.fail("Choose an element by ref, or x/y coordinates to {s}.", .{verb});
        const y = number(args, "y") orelse return self.fail("Choose an element by ref, or x/y coordinates to {s}.", .{verb});
        return .{ .x = x, .y = y };
    }

    fn mouse(self: *Page, kind: []const u8, p: Point, button: []const u8) !void {
        _ = try self.devtools("Input.dispatchMouseEvent", .{ .type = kind, .x = p.x, .y = p.y, .button = button, .clickCount = 1 });
    }

    fn click(self: *Page, p: Point) !void {
        try self.mouse("mouseMoved", p, "none");
        try self.mouse("mousePressed", p, "left");
        try self.mouse("mouseReleased", p, "left");
    }

    /// Click a field and select what it holds, so typing replaces it.
    fn focusAndSelect(self: *Page, ref: []const u8) !void {
        try self.click(try self.refPoint(ref));
        const resolved = try self.devtools("DOM.resolveNode", .{ .backendNodeId = try self.parseRef(ref) });
        const object = field(resolved, "object") orelse return;
        const object_id = string(object, "objectId") orelse return;
        _ = try self.devtools("Runtime.callFunctionOn", .{ .objectId = object_id, .functionDeclaration = select_contents });
    }

    fn press(self: *Page, combo: []const u8) !void {
        var modifiers: u8 = 0;
        var rest = combo;
        while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
            if (plus == rest.len - 1) break; // "Control++" presses "+"
            const bit = modifierBit(rest[0..plus]) orelse
                return self.fail("Use a standard key name such as Enter, Tab, ArrowDown, or Control+A.", .{});
            modifiers |= bit;
            rest = rest[plus + 1 ..];
        }
        const key = keyFor(rest) orelse return self.fail("Use a standard key name such as Enter, Tab, ArrowDown, or Control+A.", .{});
        // Only plain and shifted keys type text; the rest are shortcuts.
        const text: ?[]const u8 = if (modifiers & ~shift_bit == 0) key.text else null;
        if (text) |t| {
            _ = try self.devtools("Input.dispatchKeyEvent", .{ .type = "keyDown", .key = key.key, .code = key.code, .windowsVirtualKeyCode = key.vk, .modifiers = modifiers, .text = t });
        } else {
            _ = try self.devtools("Input.dispatchKeyEvent", .{ .type = "rawKeyDown", .key = key.key, .code = key.code, .windowsVirtualKeyCode = key.vk, .modifiers = modifiers });
        }
        _ = try self.devtools("Input.dispatchKeyEvent", .{ .type = "keyUp", .key = key.key, .code = key.code, .windowsVirtualKeyCode = key.vk, .modifiers = modifiers });
    }

    /// Wait for text or a selector to appear, or for a while.
    fn wait(self: *Page, args: Value) !void {
        const timeout: u32 = @intFromFloat(std.math.clamp(number(args, "timeout") orelse 5000, 0, 30_000));
        const text = string(args, "text");
        const selector = string(args, "selector");
        if (text == null and selector == null) return w32.Sleep(timeout);
        const needle = try std.json.Stringify.valueAlloc(self.arena, text orelse selector.?, .{});
        const check = if (text != null)
            try std.fmt.allocPrint(self.arena, "!!document.body && document.body.innerText.includes({s})", .{needle})
        else
            try std.fmt.allocPrint(self.arena, "!!document.querySelector({s})", .{needle});
        var waited: u32 = 0;
        while (true) : (waited += 250) {
            const found = self.evaluate(check) catch Value{ .bool = false };
            if (found == .bool and found.bool) return;
            if (waited >= timeout) return self.fail("Waited {d} ms and it didn't appear.", .{timeout});
            w32.Sleep(250);
        }
    }
};

const select_contents =
    \\function () {
    \\  if (typeof this.select === "function") { this.select(); return; }
    \\  if (!(this instanceof HTMLElement) || !this.isContentEditable) return;
    \\  const range = document.createRange();
    \\  range.selectNodeContents(this);
    \\  const selection = getSelection();
    \\  selection.removeAllRanges();
    \\  selection.addRange(range);
    \\}
;

const shift_bit: u8 = 8;

fn modifierBit(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "Alt")) return 1;
    if (std.mem.eql(u8, name, "Control")) return 2;
    if (std.mem.eql(u8, name, "Meta")) return 4;
    if (std.mem.eql(u8, name, "Shift")) return shift_bit;
    return null;
}

const Key = struct { key: []const u8, code: []const u8, vk: u16, text: ?[]const u8 = null };

const named_keys = [_]struct { []const u8, Key }{
    .{ "Enter", .{ .key = "Enter", .code = "Enter", .vk = 0x0D, .text = "\r" } },
    .{ "Tab", .{ .key = "Tab", .code = "Tab", .vk = 0x09 } },
    .{ "Backspace", .{ .key = "Backspace", .code = "Backspace", .vk = 0x08 } },
    .{ "Delete", .{ .key = "Delete", .code = "Delete", .vk = 0x2E } },
    .{ "Escape", .{ .key = "Escape", .code = "Escape", .vk = 0x1B } },
    .{ "ArrowLeft", .{ .key = "ArrowLeft", .code = "ArrowLeft", .vk = 0x25 } },
    .{ "ArrowUp", .{ .key = "ArrowUp", .code = "ArrowUp", .vk = 0x26 } },
    .{ "ArrowRight", .{ .key = "ArrowRight", .code = "ArrowRight", .vk = 0x27 } },
    .{ "ArrowDown", .{ .key = "ArrowDown", .code = "ArrowDown", .vk = 0x28 } },
    .{ "Home", .{ .key = "Home", .code = "Home", .vk = 0x24 } },
    .{ "End", .{ .key = "End", .code = "End", .vk = 0x23 } },
    .{ "PageUp", .{ .key = "PageUp", .code = "PageUp", .vk = 0x21 } },
    .{ "PageDown", .{ .key = "PageDown", .code = "PageDown", .vk = 0x22 } },
    .{ "Space", .{ .key = " ", .code = "Space", .vk = 0x20, .text = " " } },
};

/// A named key, or a single printable ASCII character.
fn keyFor(name: []const u8) ?Key {
    for (named_keys) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    if (name.len != 1 or name[0] < 0x21 or name[0] > 0x7E) return null;
    const c = name[0];
    const upper = std.ascii.toUpper(c);
    return .{
        .key = name,
        .code = if (std.ascii.isAlphabetic(c)) letter_codes[upper - 'A'] else if (std.ascii.isDigit(c)) digit_codes[c - '0'] else "",
        .vk = if (std.ascii.isAlphanumeric(c)) upper else 0,
        .text = name,
    };
}

const letter_codes = blk: {
    var codes: [26][]const u8 = undefined;
    for (&codes, 0..) |*code, i| code.* = "Key" ++ [_]u8{'A' + i};
    break :blk codes;
};
const digit_codes = blk: {
    var codes: [10][]const u8 = undefined;
    for (&codes, 0..) |*code, i| code.* = "Digit" ++ [_]u8{'0' + i};
    break :blk codes;
};

fn field(value: Value, name: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn string(value: Value, name: []const u8) ?[]const u8 {
    const v = field(value, name) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolean(value: Value, name: []const u8) ?bool {
    const v = field(value, name) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn number(value: Value, name: []const u8) ?f64 {
    return asNumber(field(value, name) orelse return null);
}

fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}
