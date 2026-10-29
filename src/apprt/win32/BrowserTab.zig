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

/// Stable for the panel's life, so Claude can name the tab.
id: u32,
owner: browser_chats.Owner,
selected_at: u64 = 0,
parked: bool = false,
on_screen: bool = false,
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
pub fn place(self: *const BrowserTab, bounds: w32.RECT, scale: f64, viewport: [2]u32, handler: *anyopaque) void {
    const c = self.controller orelse return;
    _ = c.vtable.put_Bounds(c, bounds);
    var buf: [256]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"width\":{d},\"height\":{d},\"screenWidth\":{d},\"screenHeight\":{d},\"deviceScaleFactor\":1,\"mobile\":false,\"scale\":{d:.6}}}", .{
        viewport[0], viewport[1], viewport[0], viewport[1], scale,
    }) catch return;
    _ = self.devtools("Emulation.setDeviceMetricsOverride", params, handler);
}

/// Let go of the page. A popup still waiting for its page is turned down,
/// so WebView2 doesn't open it in a window of its own.
pub fn deinit(self: *BrowserTab) void {
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
