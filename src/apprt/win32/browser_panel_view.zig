const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const wide_string = @import("wide_string.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const toolbar = @import("browser_toolbar.zig");
const dialog_bar = @import("browser_dialog_bar.zig");
const browser_settings = @import("browser_settings.zig");

const data = browser_settings.data;
const Target = toolbar.Target;
const OwnTabs = BrowserPanel.OwnTabs;

pub fn toolbarLayout(self: *const BrowserPanel) toolbar.Layout {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &client);
    var count: usize = 0;
    for (self.tab_slots[0..self.tab_count]) |tab| {
        if (tab.owner == self.owner) count += 1;
    }
    return .{ .scale = self.scale, .width = client.right, .tab_count = @min(count, data.max_tabs) };
}

fn toolbarView(self: *BrowserPanel, titles: *[data.max_tabs][]const u8, icons: *[data.max_tabs]?w32.HICON) toolbar.View {
    var own: OwnTabs = undefined;
    const shown = self.shownTabs(&own);
    const active = self.activeTab();
    var active_index: usize = shown.len;
    for (shown, 0..) |tab, i| {
        titles[i] = if (tab.title_len > 0) tab.title() else data.untitled;
        icons[i] = tab.favicon;
        if (tab == active) active_index = i;
    }
    return .{
        .palette = self.palette,
        .fonts = self.fonts,
        .titles = titles[0..shown.len],
        .icons = icons[0..shown.len],
        .active = active_index,
        .address = &self.address,
        .placeholder = data.address_placeholder,
        .hover = self.hover,
        .pressed = self.pressed,
        .can_back = if (active) |t| t.can_back else false,
        .can_forward = if (active) |t| t.can_forward else false,
        .ready = if (active) |t| t.ready else false,
        .can_add = self.hasRoom(self.owner),
        .loading = if (active) |t| t.loading else false,
        .mobile = if (active) |t| t.mobile else false,
        .expanded = self.expanded,
    };
}

pub fn enabled(self: *BrowserPanel, target: Target) bool {
    var titles: [data.max_tabs][]const u8 = undefined;
    var icons: [data.max_tabs]?w32.HICON = undefined;
    return toolbarView(self, &titles, &icons).enabled(target);
}

pub fn hit(self: *BrowserPanel, x: i32, y: i32) Target {
    const target = self.toolbarLayout().hit(x, y);
    if (target != .none) return target;
    const layout = self.dialogLayout() orelse return .none;
    return layout.hit(x, y);
}

pub fn invalidateToolbar(self: *BrowserPanel) void {
    var rect: w32.RECT = .{ .left = 0, .top = 0, .right = 100000, .bottom = self.toolbarLayout().height() + self.dialogHeight() };
    _ = w32.InvalidateRect(self.hwnd, &rect, 0);
}

pub fn paint(self: *BrowserPanel) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(self.hwnd, &ps);
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &client) == 0) return;
    const bar = self.toolbarLayout();
    const width = bar.width;
    const dialog = self.dialogLayout();
    const height = bar.height() + self.dialogHeight();
    if (width <= 0) return;

    // Around and behind the page is the terminal's color, with the edge
    // line down the left.
    var below: w32.RECT = .{ .left = 0, .top = height, .right = width, .bottom = client.bottom };
    if (w32.CreateSolidBrush(self.palette.active_tab.ref())) |brush| {
        _ = w32.FillRect(hdc, &below, brush);
        _ = w32.DeleteObject(brush);
    }
    const edge = if (self.hover == .grip or self.resizing) self.palette.text_dim else self.palette.separator;
    if (w32.CreateSolidBrush(edge.ref())) |brush| {
        var line: w32.RECT = .{ .left = 0, .top = height, .right = @max(1, self.px(1)), .bottom = client.bottom };
        _ = w32.FillRect(hdc, &line, brush);
        _ = w32.DeleteObject(brush);
    }

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(mem_dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    const old = w32.SelectObject(mem_dc, bitmap);
    defer {
        _ = w32.SelectObject(mem_dc, old);
        _ = w32.DeleteObject(bitmap);
    }
    const c: canvas_mod.Canvas = .{ .hdc = mem_dc, .pixels = @ptrCast(@alignCast(bits orelse return)), .width = width, .height = height };
    var titles: [data.max_tabs][]const u8 = undefined;
    var icons: [data.max_tabs]?w32.HICON = undefined;
    toolbar.paint(c, bar, toolbarView(self, &titles, &icons));
    if (dialog) |layout| {
        dialog_bar.paint(c, layout, .{
            .palette = self.palette,
            .fonts = self.fonts,
            .message = self.activeTab().?.dialog.?.message(),
            .field = &self.dialog_field,
            .hover = self.hover,
            .pressed = self.pressed,
        });
    }
    _ = w32.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, w32.SRCCOPY);

    const notice: ?[]const u8 = if (self.failed) data.unavailable else if (self.activeTab() == null) data.empty else null;
    if (notice) |text| {
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
        const old_font = w32.SelectObject(hdc, self.fonts.title);
        defer _ = w32.SelectObject(hdc, old_font);
        _ = w32.SetTextColor(hdc, self.palette.text_dim.ref());
        var wide: [256]u16 = undefined;
        const len = wide_string.fromUtf8(&wide, text);
        _ = w32.DrawTextW(hdc, @ptrCast(&wide), @intCast(len), &below, w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE);
    }
}

