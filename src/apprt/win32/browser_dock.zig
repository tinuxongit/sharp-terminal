//! A window's side of the browser panel: whether the globe shows, where
//! the panel sits (right of the terminal, below the strip) and how wide,
//! and opening, hiding and closing it. Nothing is created until the globe
//! is clicked, or Claude opens the browser.
const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_settings = @import("browser_settings.zig");
const browser_chats = @import("browser_chats.zig");

const log = std.log.scoped(.win32);
const alloc = std.heap.smp_allocator;

pub const PendingPage = struct { owner: browser_chats.Owner, url: []u8 };

/// Settings > AI > Tools > Browser; the quick terminal has no room for it.
pub fn enabled(self: *const Window) bool {
    return !self.is_quick_terminal and self.app.config.@"ai-tools-browser";
}

fn engine(self: *const Window) *const browser_settings.Engine {
    return browser_settings.engineFor(self.app.config.@"browser-search-engine");
}

/// Width the panel takes from the terminal, 0 while hidden.
pub fn width(self: *const Window) i32 {
    if (!self.browser_shown) return 0;
    const hwnd = self.hwnd orelse return 0;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return 0;
    if (self.browser_expanded) return @divTrunc(client.right * 4, 5);
    const wanted: i32 = if (self.browser_width) |w|
        @intFromFloat(@round(w * self.scale))
    else
        @divTrunc(client.right * browser_settings.data.width_percent, 100);
    const narrowest: i32 = @intFromFloat(@round(browser_settings.data.min_width * self.scale));
    // The terminal keeps a fifth of the window however wide the panel is.
    return @max(0, @min(@max(wanted, narrowest), @divTrunc(client.right * 4, 5)));
}

fn rect(self: *const Window) w32.RECT {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.hwnd) |hwnd| _ = w32.GetClientRect(hwnd, &client);
    return .{ .left = client.right - width(self), .top = self.tabBarHeight(), .right = client.right, .bottom = client.bottom };
}

/// The globe: show the panel, creating it the first time, or hide it.
/// A hidden panel keeps its pages.
pub fn toggle(self: *Window) void {
    if (self.browser_shown) hide(self) else _ = open(self);
}

pub fn panelOf(self: *Window) ?*BrowserPanel {
    if (!enabled(self)) return null;
    if (self.browser) |panel| return panel;
    const hwnd = self.hwnd orelse return null;
    self.browser = BrowserPanel.create(self.app.hinstance, hwnd, rect(self), self.scale, self.stripPalette(), engine(self), browser_chats.paneOwner(self), self.browser_shown) catch |err| {
        log.err("failed to open the browser panel: {}", .{err});
        return null;
    };
    self.browser.?.expanded = self.browser_expanded;
    openPending(self, self.browser.?);
    return self.browser;
}

pub fn rememberPages(self: *Window, owner: browser_chats.Owner, urls: []const []const u8) void {
    if (!enabled(self)) return;
    for (urls) |url| {
        if (!std.ascii.startsWithIgnoreCase(url, "https://") and !std.ascii.startsWithIgnoreCase(url, "http://")) continue;
        const copy = alloc.dupe(u8, url) catch return;
        self.browser_pending.append(alloc, .{ .owner = owner, .url = copy }) catch {
            alloc.free(copy);
            return;
        };
    }
    if (self.browser) |panel| openPending(self, panel);
}

fn openPending(self: *Window, panel: *BrowserPanel) void {
    for (self.browser_pending.items) |page| {
        _ = panel.openTab(page.owner, page.url);
        alloc.free(page.url);
    }
    self.browser_pending.clearRetainingCapacity();
}

fn forgetPending(self: *Window) void {
    for (self.browser_pending.items) |page| alloc.free(page.url);
    self.browser_pending.deinit(alloc);
    self.browser_pending = .empty;
}

pub fn pagesOf(self: *Window, owner: browser_chats.Owner, arena: std.mem.Allocator) []const []const u8 {
    var pages: std.ArrayList([]const u8) = .empty;
    for (self.browser_pending.items) |page| {
        if (page.owner == owner) pages.append(arena, page.url) catch return pages.items;
    }
    const panel = self.browser orelse return pages.items;
    var own: BrowserPanel.OwnTabs = undefined;
    const active = panel.activeOf(owner);
    const tabs = panel.ownTabs(owner, &own);
    for (0..2) |pass| for (tabs) |tab| {
        if ((tab == active) != (pass == 1)) continue;
        var buf: [2048]u8 = undefined;
        const url = tab.source(&buf) orelse continue;
        if (!std.ascii.startsWithIgnoreCase(url, "https://") and !std.ascii.startsWithIgnoreCase(url, "http://")) continue;
        pages.append(arena, arena.dupe(u8, url) catch continue) catch return pages.items;
    };
    return pages.items;
}

pub fn open(self: *Window) bool {
    const panel = panelOf(self) orelse return false;
    self.browser_shown = true;
    panel.show(true);
    self.handleResize();
    return true;
}

pub fn setExpanded(self: *Window, expanded: bool) void {
    self.browser_expanded = expanded;
    if (self.browser) |panel| panel.expanded = expanded;
    self.handleResize();
}

pub fn follow(self: *Window) void {
    const panel = self.browser orelse return;
    panel.showOwner(browser_chats.paneOwner(self));
}

pub fn prune(self: *Window) void {
    const panel = self.browser orelse return;
    var i = panel.tab_count;
    while (i > 0) {
        i -= 1;
        const tab = panel.tab_slots[i];
        if (!browser_chats.alive(self.app, tab.owner)) panel.closeTab(tab);
    }
}

fn hide(self: *Window) void {
    self.browser_shown = false;
    if (self.browser) |panel| panel.show(false);
    self.handleResize();
}

/// The panel's last tab closed: hide it, as closing a browser's last tab
/// closes the browser.
pub fn emptied(self: *Window) void {
    if (self.browser_shown) hide(self);
}

/// The panel's edge was dragged to `pixels` wide.
pub fn setWidth(self: *Window, pixels: i32) void {
    self.browser_width = @as(f32, @floatFromInt(pixels)) / self.scale;
    self.handleResize();
    // Mouse moves keep coming during the drag and WM_PAINT waits for a
    // quiet queue, so without this the toolbar and the terminal's edge
    // trail behind the page, which WebView2 moves at once.
    const hwnd = self.hwnd orelse return;
    _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | w32.RDW_UPDATENOW | w32.RDW_ALLCHILDREN);
}

/// Follow the window's size, scale, colors and search engine.
pub fn place(self: *Window) void {
    const panel = self.browser orelse return;
    if (self.browser_shown) panel.place(rect(self), self.scale, self.stripPalette(), engine(self));
}

/// Free the panel and its WebView2, as when the setting is switched off.
pub fn close(self: *Window) void {
    forgetPending(self);
    const panel = self.browser orelse return;
    self.browser = null;
    self.browser_shown = false;
    panel.destroy();
}
