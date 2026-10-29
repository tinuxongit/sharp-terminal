//! Where each Windows message to the browser panel goes: the toolbar's
//! pointer and keys, the address box, the shortcuts, and dragging the
//! panel's edge.
const std = @import("std");
const w32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const SearchField = @import("SearchField.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const BrowserTab = @import("BrowserTab.zig");
const toolbar = @import("browser_toolbar.zig");
const menu_theme = @import("menu_theme.zig");
const wide_string = @import("wide_string.zig");
const browser_settings = @import("browser_settings.zig");

const Target = toolbar.Target;

fn setHover(self: *BrowserPanel, target: Target) void {
    if (target.eql(self.hover)) return;
    self.hover = target;
    self.invalidateToolbar();
}

fn shownAt(self: *BrowserPanel, i: usize) ?*BrowserTab {
    var own: BrowserPanel.OwnTabs = undefined;
    const shown = self.shownTabs(&own);
    return if (i < shown.len) shown[i] else null;
}

fn act(self: *BrowserPanel, target: Target) void {
    switch (target) {
        .new_tab => _ = self.openTab(self.owner, self.engine.home),
        .tab => |i| if (shownAt(self, i)) |tab| self.select(tab),
        .tab_close => |i| if (shownAt(self, i)) |tab| self.closeTab(tab),
        .back, .forward, .reload => {
            const tab = self.activeTab() orelse return;
            const webview = tab.webview orelse return;
            _ = switch (target) {
                .back => webview.vtable.GoBack(webview),
                .forward => webview.vtable.GoForward(webview),
                else => if (tab.loading) webview.vtable.Stop(webview) else webview.vtable.Reload(webview),
            };
        },
        .page_size => pageSizeMenu(self),
        .outside => openOutside(self),
        .expand => if (w32.GetParent(self.hwnd)) |parent| {
            _ = w32.PostMessageW(parent, BrowserPanel.message_expand, @intFromBool(!self.expanded), 0);
        },
        .dialog_ok, .dialog_cancel => {
            const tab = self.activeTab() orelse return;
            self.answerDialog(tab, target == .dialog_ok, self.dialog_field.text());
        },
        .address, .grip, .none, .dialog_field => {},
    }
}

fn openOutside(self: *BrowserPanel) void {
    const tab = self.activeTab() orelse return;
    var buf: [2048]u8 = undefined;
    const url = tab.source(&buf) orelse return;
    if (!std.ascii.startsWithIgnoreCase(url, "https://") and !std.ascii.startsWithIgnoreCase(url, "http://")) return;
    var wide: [2048]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, url);
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), @ptrCast(&wide), null, null, w32.SW_SHOW);
}

const id_size_base: u32 = 1;
const id_rotate: u32 = 100;
const id_mobile: u32 = 101;

fn pageSizeMenu(self: *BrowserPanel) void {
    const tab = self.activeTab() orelse return;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    const data = browser_settings.data;
    var label: [160]u16 = undefined;
    for (data.viewports, 0..) |v, i| {
        const current = v.width == tab.viewport[0] and v.height == tab.viewport[1] and v.mobile == tab.mobile;
        _ = wide_string.fromUtf8(&label, v.name);
        _ = w32.AppendMenuW(menu, if (current) w32.MF_CHECKED else 0, id_size_base + @as(u32, @intCast(i)), @ptrCast(&label));
    }
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = wide_string.fromUtf8(&label, data.page_size.rotate);
    _ = w32.AppendMenuW(menu, 0, id_rotate, @ptrCast(&label));
    _ = wide_string.fromUtf8(&label, data.page_size.mobile);
    _ = w32.AppendMenuW(menu, if (tab.mobile) w32.MF_CHECKED else 0, id_mobile, @ptrCast(&label));
    const button = self.toolbarLayout().rect(.page_size);
    var point: w32.POINT = .{ .x = button.left, .y = button.bottom };
    _ = w32.ClientToScreen(self.hwnd, &point);
    menu_theme.apply(self.palette.strip.isDark());
    const picked: u32 = @intCast(@max(0, w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, self.hwnd, null)));
    switch (picked) {
        0 => {},
        id_rotate => self.setViewport(tab, tab.viewport[1], tab.viewport[0], null),
        id_mobile => self.setViewport(tab, tab.viewport[0], tab.viewport[1], !tab.mobile),
        else => if (picked - id_size_base < data.viewports.len) {
            const v = data.viewports[picked - id_size_base];
            self.setViewport(tab, v.width, v.height, v.mobile);
        },
    }
}

fn editDialogField(self: *BrowserPanel) void {
    if (self.address.focused) stopEditing(self);
    _ = w32.SetFocus(self.hwnd);
    self.dialog_field.focus(self.hwnd, true);
    self.invalidateToolbar();
}

/// Whether `vk`, pressed with the keys held now, is one of the panel's
/// shortcuts: Ctrl+T, Ctrl+W, Ctrl+L and Ctrl+(Shift+)Tab, as in Chrome.
/// It then runs once the current message is handled.
pub fn shortcut(self: *BrowserPanel, vk: u16) bool {
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) >= 0) return false;
    switch (vk) {
        'T', 'W', 'L', w32.VK_TAB => {},
        else => return false,
    }
    const shift: usize = @intFromBool(w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0);
    _ = w32.PostMessageW(self.hwnd, BrowserPanel.message_shortcut, vk, @intCast(shift));
    return true;
}

fn runShortcut(self: *BrowserPanel, vk: u16, shift: bool) void {
    switch (vk) {
        'T' => _ = self.openTab(self.owner, self.engine.home),
        'W' => if (self.activeTab()) |tab| self.closeTab(tab),
        'L' => editAddress(self),
        w32.VK_TAB => {
            var own: BrowserPanel.OwnTabs = undefined;
            const shown = self.shownTabs(&own);
            const active = self.activeTab() orelse return;
            if (shown.len < 2) return;
            const at = std.mem.indexOfScalar(*BrowserTab, shown, active) orelse 0;
            const n = shown.len;
            self.select(shown[if (shift) (at + n - 1) % n else (at + 1) % n]);
        },
        else => {},
    }
}

/// Start typing an address: the box empties, and Escape or leaving it
/// brings back the page's address.
fn editAddress(self: *BrowserPanel) void {
    _ = w32.SetFocus(self.hwnd);
    self.address.clear();
    self.address.focus(self.hwnd, true);
    self.invalidateToolbar();
}

fn stopEditing(self: *BrowserPanel) void {
    if (!self.address.focused) return;
    self.address.focus(self.hwnd, false);
    self.showSource();
    self.invalidateToolbar();
}

/// Ask the parent for the width that puts the left edge at the pointer.
fn dragEdge(self: *BrowserPanel) void {
    var rect: w32.RECT = undefined;
    var point: w32.POINT = undefined;
    if (w32.GetWindowRect(self.hwnd, &rect) == 0 or w32.GetCursorPos_(&point) == 0) return;
    const parent = w32.GetParent(self.hwnd) orelse return;
    _ = w32.SendMessageW(parent, BrowserPanel.message_width, @intCast(@max(0, rect.right - point.x)), 0);
}

pub fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const self = BrowserPanel.fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    switch (msg) {
        w32.WM_PAINT => {
            self.paint();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            for (self.tabs()) |tab| self.placeTab(tab);
            return 0;
        },
        BrowserPanel.message_shortcut => {
            runShortcut(self, @truncate(wparam), lparam != 0);
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            if (self.resizing) {
                dragEdge(self);
                return 0;
            }
            if (!self.tracking_mouse) {
                var tme = w32.TRACKMOUSEEVENT{ .cbSize = @sizeOf(w32.TRACKMOUSEEVENT), .dwFlags = w32.TME_LEAVE, .hwndTrack = hwnd, .dwHoverTime = 0 };
                _ = w32.TrackMouseEvent(&tme);
                self.tracking_mouse = true;
            }
            const target = self.hit(x, y);
            setHover(self, if (self.enabled(target)) target else .none);
            if (self.hover == .grip) _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            setHover(self, .none);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            const target = self.hit(x, y);
            if (!self.enabled(target)) return 0;
            if (target == .address) {
                if (self.dialog_field.focused) self.dialog_field.focus(hwnd, false);
                if (!self.address.focused) editAddress(self);
                return 0;
            }
            if (target == .dialog_field) {
                editDialogField(self);
                return 0;
            }
            stopEditing(self);
            if (target == .grip) {
                self.resizing = true;
            } else if (target == .tab) {
                // Tabs switch on press, as in Chrome.
                act(self, target);
                return 0;
            }
            self.pressed = target;
            _ = w32.SetCapture(hwnd);
            self.invalidateToolbar();
            return 0;
        },
        w32.WM_LBUTTONUP => {
            const pressed = self.pressed;
            if (pressed == .none) return 0;
            self.pressed = .none;
            self.resizing = false;
            _ = w32.ReleaseCapture();
            if (self.hit(x, y).eql(pressed)) act(self, pressed);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            switch (self.hit(x, y)) {
                .tab, .tab_close => |i| act(self, .{ .tab_close = i }),
                else => {},
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            if ((lparam & 0xFFFF) == w32.HTCLIENT) {
                const cursor: ?usize = if (self.hover == .grip or self.resizing) w32.IDC_SIZEWE else if (self.hover == .address) w32.IDC_IBEAM else null;
                if (cursor) |id| {
                    _ = w32.SetCursor(w32.LoadCursorW(null, id));
                    return 1;
                }
            }
        },
        w32.WM_KEYDOWN => {
            const vk: u16 = @truncate(wparam);
            if (shortcut(self, vk)) return 0;
            if (self.dialog_field.focused) {
                switch (vk) {
                    w32.VK_RETURN => act(self, .dialog_ok),
                    w32.VK_ESCAPE => act(self, .dialog_cancel),
                    else => if (self.dialog_field.key(hwnd, vk)) self.invalidateToolbar(),
                }
                return 0;
            }
            if (!self.address.focused) return 0;
            switch (vk) {
                w32.VK_RETURN => {
                    self.address.focus(hwnd, false);
                    self.navigate(self.address.text());
                    if (self.activeTab()) |tab| if (tab.controller) |c| {
                        _ = c.vtable.MoveFocus(c, webview2.Controller.focus_programmatic);
                    };
                    self.invalidateToolbar();
                },
                w32.VK_ESCAPE => stopEditing(self),
                else => if (self.address.key(hwnd, vk)) self.invalidateToolbar(),
            }
            return 0;
        },
        w32.WM_CHAR => {
            if (self.address.focused and self.address.typeChar(@truncate(wparam))) self.invalidateToolbar();
            if (self.dialog_field.focused and self.dialog_field.typeChar(@truncate(wparam))) self.invalidateToolbar();
            return 0;
        },
        w32.WM_KILLFOCUS => {
            stopEditing(self);
            if (self.dialog_field.focused) {
                self.dialog_field.focus(hwnd, false);
                self.invalidateToolbar();
            }
            return 0;
        },
        w32.WM_TIMER => {
            if (wparam == SearchField.caret_timer) {
                self.address.blink();
                self.dialog_field.blink();
                self.invalidateToolbar();
            }
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
