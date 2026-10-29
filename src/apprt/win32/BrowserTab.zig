//! One tab of the browser panel: its WebView2 page, title, history state
//! and log, and the calls that act on that page. browser_engine.zig
//! creates the page and keeps these fields current from its events.
const BrowserTab = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const browser_log = @import("browser_log.zig");
const browser_chats = @import("browser_chats.zig");
const browser_settings = @import("browser_settings.zig");

/// Stable for the panel's life, so Claude can name the tab.
id: u32,
owner: browser_chats.Owner,
selected_at: u64 = 0,
parked: bool = false,
on_screen: bool = false,
loading: bool = false,
dialog: ?Dialog = null,
frames: Frames = .{},
requests: Requests = .{},
viewport: [2]u32 = .{ browser_settings.data.viewport_width, browser_settings.data.viewport_height },
mobile: bool = false,
color_scheme: ColorScheme = .none,
motion: Motion = .none,
pointer: ?[2]f64 = null,
drag_data: ?[]u8 = null,
controller: ?*webview2.Controller = null,
webview: ?*webview2.WebView = null,
/// The page has its identity and size and has started loading; until
/// then neither the user nor Claude may use it.
ready: bool = false,
title_buf: [256]u8 = undefined,
title_len: usize = 0,
can_back: bool = false,
can_forward: bool = false,
/// What the page reported, for Claude's browser_logs.
page_log: browser_log.Log = .{},
/// What the tab loads once it is ready.
first: First,

pub const First = union(enum) {
    /// An address, owned by the tab until it is loaded.
    url: []u8,
    /// A window the page opened: the tab becomes that window, so the page
    /// that opened it keeps talking to it (sign-in popups need that).
    popup: struct { args: *webview2.NewWindowArgs, deferral: *webview2.Deferral },
};

pub const DialogKind = enum(c_int) { alert = 0, confirm = 1, prompt = 2, beforeunload = 3 };

pub const ColorScheme = enum { none, light, dark };
pub const Motion = enum { none, reduce, @"no-preference" };

pub fn emulateMedia(self: *const BrowserTab, handler: *anyopaque) void {
    var buf: [300]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"features\":[{{\"name\":\"prefers-color-scheme\",\"value\":\"{s}\"}},{{\"name\":\"prefers-reduced-motion\",\"value\":\"{s}\"}}]}}", .{
        if (self.color_scheme == .none) "" else @tagName(self.color_scheme),
        if (self.motion == .none) "" else @tagName(self.motion),
    }) catch return;
    _ = self.devtools("Emulation.setEmulatedMedia", params, handler);
}

pub const Dialog = struct {
    args: *webview2.ScriptDialogArgs,
    deferral: *webview2.Deferral,
    kind: DialogKind,
    message_buf: [512]u8 = undefined,
    message_len: u16 = 0,
    default_buf: [256]u8 = undefined,
    default_len: u16 = 0,

    pub fn message(self: *const Dialog) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn defaultText(self: *const Dialog) []const u8 {
        return self.default_buf[0..self.default_len];
    }
};

pub fn answerDialog(self: *BrowserTab, accept: bool, text: []const u8) void {
    const d = self.dialog orelse return;
    self.dialog = null;
    if (accept) {
        if (d.kind == .prompt) {
            if (std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, text)) |wide| {
                defer std.heap.smp_allocator.free(wide);
                _ = d.args.vtable.put_ResultText(d.args, wide);
            } else |_| {}
        }
        _ = d.args.vtable.Accept(d.args);
    }
    _ = d.deferral.vtable.Complete(d.deferral);
    d.deferral.release();
    d.args.release();
}

const Id = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,

    fn of(text: []const u8) ?Id {
        if (text.len > 64) return null;
        var id: Id = .{ .len = @intCast(text.len) };
        @memcpy(id.buf[0..text.len], text);
        return id;
    }

    pub fn get(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Frame = struct { key: u32, session: Id, target: Id, parent: Id };

pub const Frames = struct {
    items: [32]Frame = undefined,
    len: usize = 0,
    next_key: u32 = 1,

    pub fn all(self: *const Frames) []const Frame {
        return self.items[0..self.len];
    }

    pub fn add(self: *Frames, session: []const u8, target: []const u8, parent: []const u8) bool {
        if (self.len == self.items.len) return false;
        self.items[self.len] = .{
            .key = self.next_key,
            .session = Id.of(session) orelse return false,
            .target = Id.of(target) orelse return false,
            .parent = Id.of(parent) orelse return false,
        };
        self.next_key += 1;
        self.len += 1;
        return true;
    }

    pub fn remove(self: *Frames, session: []const u8) void {
        var i: usize = 0;
        while (i < self.len) {
            if (std.mem.eql(u8, self.items[i].session.get(), session) or std.mem.eql(u8, self.items[i].parent.get(), session)) {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
            } else i += 1;
        }
    }
};

pub const Requests = struct {
    ids: [128]Id = undefined,
    urls: [128][300]u8 = undefined,
    url_lens: [128]u16 = undefined,
    next: usize = 0,
    count: usize = 0,

    pub fn remember(self: *Requests, id: []const u8, url: []const u8) void {
        const slot = self.next;
        self.ids[slot] = Id.of(id) orelse return;
        var n = @min(url.len, self.urls[slot].len);
        while (n < url.len and n > 0 and url[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(self.urls[slot][0..n], url[0..n]);
        self.url_lens[slot] = @intCast(n);
        self.next = (slot + 1) % self.ids.len;
        self.count = @min(self.count + 1, self.ids.len);
    }

    pub fn urlOf(self: *const Requests, id: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.ids[i].get(), id)) return self.urls[i][0..self.url_lens[i]];
        }
        return null;
    }
};

pub fn title(self: *const BrowserTab) []const u8 {
    return self.title_buf[0..self.title_len];
}

pub fn setTitle(self: *BrowserTab, text: []const u8) void {
    var n = @min(text.len, self.title_buf.len);
    while (n < text.len and n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(self.title_buf[0..n], text[0..n]);
    self.title_len = n;
}

/// The page's address, written into `out`.
pub fn source(self: *const BrowserTab, out: []u8) ?[]const u8 {
    const webview = self.webview orelse return null;
    var uri: ?[*:0]u16 = null;
    if (webview.vtable.get_Source(webview, &uri) < 0) return null;
    defer w32.CoTaskMemFree(uri);
    return out[0..wide_string.toUtf8(out, std.mem.span(uri orelse return null))];
}

/// Call a DevTools Protocol method; `handler` gets its answer. False when
/// the page doesn't exist yet, and then the handler is never called.
pub fn devtools(self: *const BrowserTab, method: []const u8, params: []const u8, handler: *anyopaque) bool {
    const webview = self.webview orelse return false;
    const alloc = std.heap.smp_allocator;
    const method_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, method) catch return false;
    defer alloc.free(method_w);
    const params_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, params) catch return false;
    defer alloc.free(params_w);
    return webview.vtable.CallDevToolsProtocolMethod(webview, method_w, params_w, handler) >= 0;
}

pub fn devtoolsIn(self: *const BrowserTab, session: []const u8, method: []const u8, params: []const u8, handler: *anyopaque) bool {
    if (session.len == 0) return self.devtools(method, params, handler);
    const webview = self.webview orelse return false;
    const v15 = webview.as15() orelse return false;
    defer _ = v15.release();
    const alloc = std.heap.smp_allocator;
    const session_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, session) catch return false;
    defer alloc.free(session_w);
    const method_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, method) catch return false;
    defer alloc.free(method_w);
    const params_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, params) catch return false;
    defer alloc.free(params_w);
    return v15.vtable.CallDevToolsProtocolMethodForSession(v15, session_w, method_w, params_w, handler) >= 0;
}

pub fn navigate(self: *const BrowserTab, url: []const u8) void {
    const webview = self.webview orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, url) catch return;
    defer std.heap.smp_allocator.free(wide);
    _ = webview.vtable.Navigate(webview, wide);
}

pub fn show(self: *const BrowserTab, shown: bool) void {
    if (self.controller) |c| _ = c.vtable.put_IsVisible(c, @intFromBool(shown));
}

/// Place the page in the panel at `bounds` and fit the fixed layout size
/// into it: `scale` is how much smaller (or larger) than its CSS pixels
/// the page shows.
pub fn place(self: *const BrowserTab, bounds: w32.RECT, scale: f64, handler: *anyopaque) void {
    const c = self.controller orelse return;
    _ = c.vtable.put_Bounds(c, bounds);
    var buf: [400]u8 = undefined;
    const landscape = self.viewport[0] > self.viewport[1];
    const params = std.fmt.bufPrint(&buf, "{{\"width\":{d},\"height\":{d},\"screenWidth\":{d},\"screenHeight\":{d},\"deviceScaleFactor\":1,\"mobile\":{},\"scale\":{d:.6},\"screenOrientation\":{{\"type\":\"{s}\",\"angle\":{d}}}}}", .{
        self.viewport[0], self.viewport[1], self.viewport[0], self.viewport[1], self.mobile, scale,
        if (landscape) "landscapePrimary" else "portraitPrimary", @as(u32, if (landscape) 90 else 0),
    }) catch return;
    _ = self.devtools("Emulation.setDeviceMetricsOverride", params, handler);
}

/// Let go of the page. A popup still waiting for its page is turned down,
/// so WebView2 doesn't open it in a window of its own.
pub fn setDragData(self: *BrowserTab, json: ?[]const u8) void {
    if (self.drag_data) |old| std.heap.smp_allocator.free(old);
    self.drag_data = if (json) |j| std.heap.smp_allocator.dupe(u8, j) catch null else null;
}

pub fn deinit(self: *BrowserTab) void {
    self.answerDialog(false, "");
    self.setDragData(null);
    switch (self.first) {
        .url => |url| std.heap.smp_allocator.free(url),
        .popup => |p| {
            _ = p.args.vtable.put_Handled(p.args, 1);
            _ = p.deferral.vtable.Complete(p.deferral);
            p.deferral.release();
            p.args.release();
        },
    }
    self.first = .{ .url = &.{} };
    if (self.controller) |c| _ = c.vtable.Close(c);
    if (self.webview) |v| v.release();
    if (self.controller) |c| c.release();
    self.webview = null;
    self.controller = null;
}
