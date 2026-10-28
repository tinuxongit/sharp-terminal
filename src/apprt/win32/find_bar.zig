//! The find bar of a terminal pane (Ctrl+Shift+F): a native edit box over
//! the pane, the "selected/total" match count beside it, and its keys.
//! Search itself runs in the core; this only shows and feeds it.
const std = @import("std");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const log = std.log.scoped(.win32);
const Surface = @import("Surface.zig");

/// Store the total match count from the search_total action and refresh
/// the "selected/total" label in the search bar.
pub fn setSearchTotal(self: *Surface, total: ?usize) void {
    self.search_total = total;
    updateSearchCountLabel(self);
}

/// Store the selected match index (0-based) from the search_selected
/// action and refresh the "selected/total" label in the search bar.
pub fn setSearchSelected(self: *Surface, selected: ?usize) void {
    self.search_selected = selected;
    updateSearchCountLabel(self);
}

pub fn updateSearchCountLabel(self: *Surface) void {
    const label = self.search_count_label orelse return;
    var buf8: [32]u8 = undefined;
    const text8: []const u8 = blk: {
        const total = self.search_total orelse break :blk "";
        if (total == 0) break :blk "0/0";
        if (self.search_selected) |sel| {
            break :blk std.mem.print(&buf8, "{d}/{d}", .{ sel + 1, total }) catch "";
        }
        break :blk std.mem.print(&buf8, "-/{d}", .{total}) catch "";
    };
    var buf16: [64]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch 0;
    buf16[len16] = 0;
    _ = w32.SetWindowTextW(label, @ptrCast(&buf16));
}

pub fn setSearchActive(self: *Surface, active: bool, needle: [:0]const u8) void {
    if (active) {
        // Close command palette if open (mutual exclusion)
        if (self.palette_active) {
            self.setCommandPaletteActive(false);
        }
        self.search_active = true;
        ensureSearchBar(self);
        if (self.search_hwnd) |popup| {
            positionSearchBar(self);
            _ = w32.ShowWindow(popup, w32.SW_SHOW);

            // Set the search text if provided
            if (needle.len > 0) {
                if (self.search_edit) |edit| {
                    var wbuf: [512]u16 = undefined;
                    const wlen = wide_string.fromUtf8(&wbuf, needle);
                    if (wlen > 0) {
                        _ = w32.SetWindowTextW(edit, @ptrCast(&wbuf));
                    }
                }
            }

            // Focus the edit control
            if (self.search_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.search_active = false;
        self.search_total = null;
        self.search_selected = null;
        updateSearchCountLabel(self);
        if (self.search_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0); // SW_HIDE
        }
        // Return focus to the main window
        if (self.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}

/// Create the search popup window if it doesn't exist. The popup is a
/// small top-level window (WS_POPUP) that floats over the main window.
/// A child Edit control inside it handles the actual text input.
/// We can't use a child window of the main HWND because OpenGL covers
/// the entire client area and paints over child controls.
pub fn ensureSearchBar(self: *Surface) void {
    if (self.search_hwnd != null) return;

    const s = self.scale;
    const bar_w: i32 = @intFromFloat(@round(310.0 * s));
    const bar_h: i32 = @intFromFloat(@round(32.0 * s));
    const pad: i32 = @intFromFloat(@round(4.0 * s));

    // Create the popup container (no title bar, tool window so it
    // doesn't appear in the taskbar). Parent is the top-level Window
    // HWND so it floats above the terminal surface.
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        bar_w,
        bar_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the Edit control inside the popup, leaving room on the right
    // for the match-count label ("3/17").
    const count_w: i32 = @intFromFloat(@round(64.0 * s));
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        bar_w - pad * 2 - 2 - count_w,
        bar_h - pad * 2 - 2,
        popup,
        @ptrFromInt(@as(usize, Surface.SEARCH_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Right-aligned match-count label, filled by search_total /
    // search_selected actions (see setSearchTotal/setSearchSelected).
    self.search_count_label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_RIGHT | w32.SS_CENTERIMAGE,
        bar_w - pad - count_w,
        pad,
        count_w - pad,
        bar_h - pad * 2 - 2,
        popup,
        null,
        self.app.hinstance,
        null,
    );

    // Set a readable font (DPI-scaled)
    self.search_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.search_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.search_count_label) |label| {
            _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    // Set GWLP_USERDATA on the popup so surfaceWndProc can route
    // WM_COMMAND (EN_CHANGE) and WM_CTLCOLOREDIT to this Surface.
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.search_hwnd = popup;
    self.search_edit = edit;
}

/// Position the search popup at the top-right corner of the parent window.
pub fn positionSearchBar(self: *Surface) void {
    const popup = self.search_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const bar_width: i32 = @intFromFloat(@round(310.0 * s));
        const bar_height: i32 = @intFromFloat(@round(32.0 * s));
        const padding: i32 = @intFromFloat(@round(8.0 * s));
        const title_bar: i32 = @intFromFloat(@round(32.0 * s));
        // Position at top-right of the window, below the title bar
        _ = w32.MoveWindow(
            popup,
            rect.right - bar_width - padding,
            rect.top + title_bar + padding,
            bar_width,
            bar_height,
            1,
        );
    }
}

/// Handle text changes in the search edit control (EN_CHANGE).
pub fn handleSearchChange(self: *Surface) void {
    if (!self.core_surface_ready) return;
    const search = self.search_edit orelse return;

    // Get the current search text
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(search, &wbuf, @intCast(wbuf.len)));

    // A UTF-16 unit expands to at most 3 UTF-8 bytes, and the conversion
    // does not bounds-check, so size for the worst case.
    var utf8_buf: [wbuf.len * 3]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;

    // Need a null-terminated slice for performBindingAction
    var needle_buf: [utf8_buf.len + 1]u8 = undefined;
    @memcpy(needle_buf[0..utf8_len], utf8_buf[0..utf8_len]);
    needle_buf[utf8_len] = 0;
    const needle: [:0]const u8 = needle_buf[0..utf8_len :0];

    _ = self.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

/// Handle key events in the search bar. Returns true if handled.
pub fn handleSearchKey(self: *Surface, vk: u16) bool {
    if (!self.core_surface_ready) return false;

    switch (vk) {
        w32.VK_RETURN => {
            // Enter = next match, Shift+Enter = previous match
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const nav: input.Binding.Action = if (shift)
                .{ .navigate_search = .previous }
            else
                .{ .navigate_search = .next };
            _ = self.core_surface.performBindingAction(nav) catch |err| {
                log.err("navigate_search error: {}", .{err});
            };
            return true;
        },
        w32.VK_ESCAPE => {
            _ = self.core_surface.performBindingAction(.end_search) catch |err| {
                log.err("end_search error: {}", .{err});
            };
            return true;
        },
        else => return false,
    }
}
