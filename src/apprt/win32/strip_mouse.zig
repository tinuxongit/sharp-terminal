//! The tab strip's mouse: clicks, hover and leaving, closing tabs Chrome's
//! way, dragging them to reorder, and the right-click tab menu.
const std = @import("std");
const closed_tabs = @import("closed_tabs.zig");
const w32 = @import("win32.zig");
const tab_strip = @import("tab_strip.zig");
const menu_theme = @import("menu_theme.zig");
const workspace = @import("workspace.zig");
const tab_rename = @import("tab_rename.zig");
const browser_dock = @import("browser_dock.zig");
const log = std.log.scoped(.win32);
const Window = @import("Window.zig");

/// Closing with the mouse keeps the other tabs at their width, as Chrome
/// does, so the next close button lands under the pointer. The width is
/// released once the pointer leaves the tabs.
pub fn closeTabFromStrip(self: *Window, index: usize) void {
    self.frozen_tab_width = self.stripLayout().tabWidth();
    self.requestCloseTabs(&.{self.tabId(index)});
}

pub fn releaseFrozenTabWidth(self: *Window) void {
    if (self.frozen_tab_width == null) return;
    self.frozen_tab_width = null;
    self.invalidateTabBar();
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    tab_rename.cancelTabRename(self);

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;

    self.active_tab = to;
    self.invalidateTabBar();
    self.app.saveSession();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
pub fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    trackMouseLeave(self);
    const part = self.stripLayout().hitTest(x, y);
    self.setStripHover(part);
    switch (part) {
        .tab, .tab_close => {},
        else => releaseFrozenTabWidth(self),
    }
}

/// Ask for WM_MOUSELEAVE, which clears hover in the strip and sidebar.
pub fn trackMouseLeave(self: *Window) void {
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;
const TAB_CTX_REOPEN: usize = 9005;

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
pub fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    const clicked_tab: ?usize = switch (self.stripLayout().hitTest(x, y)) {
        .tab, .tab_close => |i| i,
        else => null,
    };
    showTabMenu(self, clicked_tab, x, y);
}

/// Native menus follow the terminal's background, light or dark.
pub fn menusDark(self: *const Window) bool {
    const bg = self.app.config.background;
    return tab_strip.Rgb.isDark(.{ .r = bg.r, .g = bg.g, .b = bg.b });
}

/// The tab right-click menu at client point (x, y).
pub fn showTabMenu(self: *Window, clicked_tab: ?usize, x: i16, y: i16) void {

    // If clicked on empty area (not a tab), only show "New Tab".
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));
    _ = w32.AppendMenuW(menu, if (closed_tabs.any()) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_REOPEN, std.unicode.utf8ToUtf16LeStringLiteral("Reopen Closed Tab"));

    menu_theme.apply(menusDark(self));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.requestCloseTabs(&.{self.tabId(tab)});
        },
        TAB_CTX_CLOSE_OTHERS, TAB_CTX_CLOSE_RIGHT => {
            const tab = clicked_tab orelse return;
            const first = if (cmd == TAB_CTX_CLOSE_RIGHT) tab + 1 else 0;
            var ids: [Window.MAX_TABS]u64 = undefined;
            var count: usize = 0;
            for (first..self.tab_count) |i| {
                if (i == tab) continue;
                ids[count] = self.tabId(i);
                count += 1;
            }
            self.requestCloseTabs(ids[0..count]);
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        TAB_CTX_REOPEN => _ = closed_tabs.reopen(self),
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
pub fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    releaseFrozenTabWidth(self);
    workspace.setSidebarHover(self, .none);
    // Caption buttons are tracked by WM_NCMOUSELEAVE instead.
    if (!self.strip_hover.isCaptionButton()) self.setStripHover(.none);
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
pub fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    switch (self.stripLayout().hitTest(x, y)) {
        .new_tab => _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .tab_close => |i| Window.strip_mouse.closeTabFromStrip(self, i),
        .settings => self.openSettings(),
        .browser => browser_dock.toggle(self),
        .update => self.app.restartToUpdate(self.hwnd),
        .new_tab_menu => self.showNewTabMenu(),
        .tab => |i| {
            self.selectTabIndex(i);
            // Start tracking potential tab drag
            self.drag_tab = @intCast(i);
            self.drag_start_x = x;
            self.drag_active = false;
            if (self.hwnd) |h| _ = w32.SetCapture(h);
            self.invalidateTabBar();
        },
        else => {},
    }
}
