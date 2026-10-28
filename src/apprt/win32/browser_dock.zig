//! A window's side of the browser panel: whether the globe shows, where
//! the panel sits (right of the terminal, below the strip), and opening,
//! hiding and closing it. Nothing is created until the globe is clicked.
const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const BrowserPanel = @import("BrowserPanel.zig");

const log = std.log.scoped(.win32);

/// Settings > AI > Tools > Browser; the quick terminal has no room for it.
pub fn enabled(self: *const Window) bool {
    return !self.is_quick_terminal and self.app.config.@"ai-tools-browser";
}

/// Width the panel takes from the terminal, 0 while hidden.
pub fn width(self: *const Window) i32 {
    if (!self.browser_shown) return 0;
    const hwnd = self.hwnd orelse return 0;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return 0;
    const share = @divTrunc(client.right * BrowserPanel.data.width_percent, 100);
    const narrowest: i32 = @intFromFloat(@round(BrowserPanel.data.min_width * self.scale));
    // The terminal keeps a fifth of the window however small it gets.
    return @min(@max(share, narrowest), @divTrunc(client.right * 4, 5));
}

fn rect(self: *const Window) w32.RECT {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.hwnd) |hwnd| _ = w32.GetClientRect(hwnd, &client);
    return .{ .left = client.right - width(self), .top = self.tabBarHeight(), .right = client.right, .bottom = client.bottom };
}

/// The globe: show the panel, creating it the first time, or hide it.
/// A hidden panel keeps its page.
pub fn toggle(self: *Window) void {
    if (!enabled(self)) return;
    const hwnd = self.hwnd orelse return;
    self.browser_shown = !self.browser_shown;
    if (self.browser) |panel| {
        panel.show(self.browser_shown);
    } else if (self.browser_shown) {
        self.browser = BrowserPanel.create(self.app.core_app.alloc, self.app.hinstance, hwnd, rect(self), self.scale, self.stripPalette()) catch |err| {
            log.err("failed to open the browser panel: {}", .{err});
            self.browser_shown = false;
            return;
        };
    }
    self.handleResize();
}

/// Follow the window's size, scale and colors.
pub fn place(self: *Window) void {
    const panel = self.browser orelse return;
    if (self.browser_shown) panel.place(rect(self), self.scale, self.stripPalette());
}

/// Free the panel and its WebView2, as when the setting is switched off.
pub fn close(self: *Window) void {
    const panel = self.browser orelse return;
    self.browser = null;
    self.browser_shown = false;
    panel.destroy(self.app.core_app.alloc);
}
