//! The browser tab one of Claude's tool calls acts on, from the MCP
//! server's thread: DevTools calls through browser_remote, waiting for
//! pages to load, and the mouse and keyboard. Its failures are worded for
//! Claude. Ported from Citropy's desktop/browser.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const w32 = @import("win32.zig");
const remote = @import("browser_remote.zig");
const browser_settings = @import("browser_settings.zig");
const json_read = @import("json_read.zig");
const Chat = @import("browser_chats.zig").Chat;
const field = json_read.field;
const string = json_read.string;
const number = json_read.number;
const asNumber = json_read.asNumber;

pub const Point = struct { x: f64, y: f64 };

/// An empty struct writes as {}; an empty tuple (.{}) would write [].
pub const no_params = struct {}{};

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
pub const TabInfo = struct { id: u32, title: []const u8, url: []const u8, active: bool };

pub const Frame = struct { key: u32, session: []const u8, target: []const u8, parent: []const u8 };

pub const Page = struct {
    arena: Allocator,
    chat: *const Chat,
    failure: ?[]const u8 = null,
    /// The tab the call acts on, once chosen.
    tab: u32 = 0,
    frame_list: ?[]const Frame = null,

    pub fn fail(self: *Page, comptime fmt: []const u8, args: anytype) error{ Failed, OutOfMemory } {
        self.failure = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.Failed;
    }

    pub fn remoteCall(self: *Page, op: remote.Op, timeout_ms: u32) ![]const u8 {
        const answer = remote.call(self.chat, op, timeout_ms) catch |err| return switch (err) {
            error.Unavailable => self.fail("Sharp couldn't reach its browser.", .{}),
            error.TimedOut => self.fail("The browser didn't answer in time.", .{}),
        };
        defer answer.free();
        const text = try self.arena.dupe(u8, answer.text);
        if (!answer.ok) return self.fail("{s}", .{if (text.len > 0) text else "The browser couldn't do that."});
        return text;
    }

    /// Call a DevTools method; its error message becomes the failure.
    pub fn devtools(self: *Page, method: []const u8, params: anytype) !Value {
        return self.devtoolsIn("", method, params);
    }

    pub fn devtoolsIn(self: *Page, session: []const u8, method: []const u8, params: anytype) !Value {
        const json = try std.json.Stringify.valueAlloc(self.arena, params, .{ .emit_null_optional_fields = false });
        const answer = remote.callWatching(self.chat, .{ .devtools = .{ .tab = self.tab, .session = session, .method = method, .params = json } }, 30_000, self.tab) catch |err| return switch (err) {
            error.Unavailable => self.fail("Sharp couldn't reach its browser.", .{}),
            error.TimedOut => self.fail("The page didn't answer {s} in time.", .{method}),
            error.Dialog => self.dialogFailure(),
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
    pub fn evaluate(self: *Page, expression: []const u8) !Value {
        const answer = try self.devtools("Runtime.evaluate", .{ .expression = expression, .returnByValue = true, .awaitPromise = true });
        if (field(answer, "exceptionDetails")) |details| {
            const description = if (field(details, "exception")) |e| string(e, "description") else null;
            return self.fail("{s}", .{description orelse string(details, "text") orelse "The script threw."});
        }
        const result = field(answer, "result") orelse return .null;
        return field(result, "value") orelse .null;
    }

    pub const Dialog = struct { kind: []const u8, message: []const u8 };

    pub fn dialog(self: *Page) !?Dialog {
        const json = try self.remoteCall(.{ .dialog = .{ .tab = self.tab } }, 5_000);
        if (json.len == 0) return null;
        return std.json.parseFromSliceLeaky(Dialog, self.arena, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }

    fn dialogFailure(self: *Page) error{ Dialog, Failed, OutOfMemory } {
        const open = (self.dialog() catch null) orelse return self.fail("The page stopped answering.", .{});
        self.failure = try std.fmt.allocPrint(self.arena, "A {s} dialog is open on the page: {s}\nAnswer it with browser_action dialog (accept true or false, and text for a prompt).", .{ open.kind, open.message });
        return error.Dialog;
    }

    pub fn frames(self: *Page) ![]const Frame {
        if (self.frame_list) |list| return list;
        const json = try self.remoteCall(.{ .frames = .{ .tab = self.tab } }, 5_000);
        const list = std.json.parseFromSliceLeaky([]const Frame, self.arena, json, .{ .allocate = .alloc_always }) catch
            return self.fail("The browser listed its frames unreadably.", .{});
        self.frame_list = list;
        return list;
    }

    pub fn parseId(self: *Page, text: []const u8) !u32 {
        return std.fmt.parseInt(u32, text, 10) catch self.fail("The browser gave no tab.", .{});
    }

    /// Act on the tab the call names, or the active one, and show it: the
    /// user sees what Claude does, and hidden pages don't draw.
    pub fn selectTab(self: *Page, args: Value) !void {
        const wanted = number(args, "tab") orelse 0;
        if (wanted < 0 or wanted > std.math.maxInt(u32)) return self.fail("There is no such tab. browser_tabs lists them.", .{});
        self.tab = try self.parseId(try self.remoteCall(.{ .select = .{ .tab = @intFromFloat(wanted) } }, 5_000));
    }

    pub fn tabs(self: *Page) ![]const TabInfo {
        const json = try self.remoteCall(.tabs, 5_000);
        return std.json.parseFromSliceLeaky([]const TabInfo, self.arena, json, .{ .allocate = .alloc_always }) catch
            self.fail("The browser listed its tabs unreadably.", .{});
    }

    /// Wait until the tab's page exists; it starts when the tab opens.
    pub fn waitReady(self: *Page) !void {
        var waited: u32 = 0;
        while (waited < 20_000) : (waited += 200) {
            const answer = remote.call(self.chat, .{ .ready = .{ .tab = self.tab } }, 5_000) catch return self.fail("Sharp couldn't reach its browser.", .{});
            defer answer.free();
            if (answer.ok) return;
            if (answer.text.len > 0) return self.fail("{s}", .{try self.arena.dupe(u8, answer.text)});
            w32.Sleep(200);
        }
        return self.fail("The browser is still starting. Try again in a moment.", .{});
    }

    /// Give a navigation an action may have started time to load. A new
    /// tab starts on about:blank, so `leaving_blank` waits past that.
    pub fn settle(self: *Page, leaving_blank: bool) void {
        w32.Sleep(300);
        var waited: u32 = 0;
        while (waited < 10_000) : (waited += 250) {
            const state = self.evaluate("[document.readyState, location.href]") catch |err| {
                if (err == error.Dialog) break;
                w32.Sleep(250);
                continue;
            };
            if (state == .array and state.array.items.len == 2 and state.array.items[0] == .string and state.array.items[1] == .string) {
                const complete = std.mem.eql(u8, state.array.items[0].string, "complete");
                const blank = std.mem.eql(u8, state.array.items[1].string, "about:blank");
                if (complete and !(leaving_blank and blank)) break;
            }
            w32.Sleep(250);
        }
        // Calls that failed mid-navigation are not the action's failure.
        self.failure = null;
        self.frame_list = null;
    }

    pub fn navigate(self: *Page, typed: []const u8) !void {
        const url = try self.webAddress(typed);
        const answer = try self.devtools("Page.navigate", .{ .url = url });
        if (string(answer, "errorText")) |err| if (err.len > 0) return self.fail("Couldn't open {s}: {s}", .{ url, err });
        self.settle(false);
    }

    /// The address Claude means, which must be a web page: a page asking
    /// Claude to open file:// or the browser's own pages could otherwise
    /// read the user's files or settings through it.
    pub fn webAddress(self: *Page, typed: []const u8) ![]const u8 {
        var buf: [2048]u8 = undefined;
        const url = browser_settings.addressFor(std.mem.trim(u8, typed, " \t"), browser_settings.engineFor(null).search, &buf) orelse
            return self.fail("Give an address to open.", .{});
        const web = std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://") or
            std.ascii.eqlIgnoreCase(url, "about:blank");
        if (!web) return self.fail("Only http and https addresses can be opened.", .{});
        return self.arena.dupe(u8, url);
    }

    pub fn info(self: *Page) !PageInfo {
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
    pub fn header(self: *Page, w: *std.Io.Writer) !void {
        const i = try self.info();
        try w.print("{s}\n{s}\nViewport: {d} × {d}. Screenshot coordinates use these dimensions. Use [ref=N] values with browser_action ref.", .{ i.title, i.url, i.width, i.height });
        const unread = try self.remoteCall(.{ .logs = .{ .tab = self.tab, .since_ms = 0, .clear = false } }, 5_000);
        const errors = std.mem.count(u8, unread, "[error]");
        if (errors > 0) try w.print(" {d} unread error{s} in browser_logs.", .{ errors, if (errors == 1) "" else "s" });
    }

    /// The viewport as a JPEG, in CSS pixels so its coordinates are the
    /// ones click takes.
    pub fn screenshot(self: *Page) ![]const u8 {
        const i = try self.info();
        const answer = try self.devtools("Page.captureScreenshot", .{
            .format = "jpeg",
            .quality = 80,
            .clip = .{ .x = i.scroll_x, .y = i.scroll_y, .width = i.width, .height = i.height, .scale = 1 / @max(i.pixel_ratio, 0.1) },
        });
        return string(answer, "data") orelse self.fail("The page gave no picture.", .{});
    }

    pub fn mouse(self: *Page, kind: []const u8, p: Point, button: []const u8) !void {
        _ = try self.devtools("Input.dispatchMouseEvent", .{ .type = kind, .x = p.x, .y = p.y, .button = button, .clickCount = 1 });
    }

    pub fn click(self: *Page, p: Point) !void {
        try self.mouse("mouseMoved", p, "none");
        try self.mouse("mousePressed", p, "left");
        try self.mouse("mouseReleased", p, "left");
    }

    pub fn press(self: *Page, combo: []const u8) !void {
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
    pub fn wait(self: *Page, args: Value) !void {
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
