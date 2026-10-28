//! The browser panel beside the terminal: a child window with a toolbar
//! Sharp draws (tabs, back, forward, reload, address) over the active
//! tab's page. A window creates it the first time its globe is clicked,
//! and only while Settings > AI > Tools > Browser is on, so otherwise no
//! browser loads. browser_engine.zig drives WebView2 for it.
const BrowserPanel = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const SearchField = @import("SearchField.zig");
const BrowserTab = @import("BrowserTab.zig");
const browser_engine = @import("browser_engine.zig");
const toolbar = @import("browser_toolbar.zig");
const browser_settings = @import("browser_settings.zig");
const browser_messages = @import("browser_messages.zig");

const data = browser_settings.data;
const Engine = browser_settings.Engine;

const alloc = std.heap.smp_allocator;

/// Sent to the parent while the left edge is dragged; wparam is the width
/// the panel asks for, in pixels.
pub const message_width: u32 = w32.WM_APP + 20;
/// Posted to the parent when the last tab closes.
pub const message_empty: u32 = w32.WM_APP + 21;
/// Posted to itself, so a shortcut pressed in a page runs after the page's
/// own event is over (it may close that page).
pub const message_shortcut: u32 = w32.WM_APP + 22;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Browser");
var class_atom: u16 = 0;

const Target = toolbar.Target;

hwnd: w32.HWND,
scale: f32,
palette: tab_strip.Palette,
fonts: tab_strip.Fonts = .{},
engine: *const Engine,
environment: ?*webview2.Environment = null,
tab_slots: [data.max_tabs]*BrowserTab = undefined,
tab_count: usize = 0,
active: usize = 0,
next_id: u32 = 1,
/// WebView2 could not start, so the panel says why instead.
failed: bool = false,
shown: bool = true,
/// Shows the active page's address, or what is being typed.
address: SearchField = .{},
hover: Target = .none,
pressed: Target = .none,
tracking_mouse: bool = false,
resizing: bool = false,

/// Create the panel over `rect` (the parent's client pixels) with one tab
/// on `first_url`, or the engine's home page.
pub fn create(instance: w32.HINSTANCE, parent: w32.HWND, rect: w32.RECT, scale: f32, palette: tab_strip.Palette, engine: *const Engine, first_url: ?[]const u8) !*BrowserPanel {
    if (class_atom == 0) {
        class_atom = w32.RegisterClassExW(&.{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &browser_messages.wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        });
        if (class_atom == 0) return error.Win32Error;
    }
    const hwnd = w32.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPCHILDREN | w32.WS_VISIBLE_STYLE,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent,
        null,
        instance,
        null,
    ) orelse return error.Win32Error;
    const self = alloc.create(BrowserPanel) catch |err| {
        _ = w32.DestroyWindow(hwnd);
        return err;
    };
    self.* = .{ .hwnd = hwnd, .scale = scale, .palette = palette, .engine = engine };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.initFonts();
    _ = self.openTab(first_url orelse engine.home);
    browser_engine.start(self);
    return self;
}

pub fn destroy(self: *BrowserPanel) void {
    for (self.tabs()) |tab| {
        tab.deinit();
        alloc.destroy(tab);
    }
    self.tab_count = 0;
    if (self.environment) |e| e.release();
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.fonts.deinit();
    alloc.destroy(self);
}

/// The panel behind `hwnd`, or null once it is gone: WebView2 may call
/// back after the window closed.
pub fn fromHwnd(hwnd: w32.HWND) ?*BrowserPanel {
    if (class_atom == 0 or @as(u16, @truncate(w32.GetClassLongW(hwnd, w32.GCW_ATOM))) != class_atom) return null;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(userdata)));
}

fn px(self: *const BrowserPanel, value: f32) i32 {
    return @intFromFloat(@round(value * self.scale));
}

fn initFonts(self: *BrowserPanel) void {
    self.fonts.deinit();
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    self.fonts = .init(hdc, self.scale);
}

pub fn fail(self: *BrowserPanel) void {
    self.failed = true;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// ---- Tabs --------------------------------------------------------------

pub fn tabs(self: *BrowserPanel) []*BrowserTab {
    return self.tab_slots[0..self.tab_count];
}

pub fn tabById(self: *BrowserPanel, id: u32) ?*BrowserTab {
    for (self.tabs()) |tab| if (tab.id == id) return tab;
    return null;
}

pub fn activeTab(self: *BrowserPanel) ?*BrowserTab {
    return if (self.active < self.tab_count) self.tab_slots[self.active] else null;
}

fn indexOf(self: *BrowserPanel, tab: *const BrowserTab) ?usize {
    for (self.tabs(), 0..) |t, i| if (t == tab) return i;
    return null;
}

/// Open `url` in a new tab and show it. Null when no more tabs fit.
pub fn openTab(self: *BrowserPanel, url: []const u8) ?u32 {
    const owned = alloc.dupe(u8, url) catch return null;
    return self.addTab(.{ .url = owned }) catch {
        alloc.free(owned);
        return null;
    };
}

/// A page opened a window: make it a tab. False when no more tabs fit,
/// and then the caller keeps what it passed.
pub fn openPopup(self: *BrowserPanel, args: *webview2.NewWindowArgs, deferral: *webview2.Deferral) bool {
    _ = self.addTab(.{ .popup = .{ .args = args, .deferral = deferral } }) catch return false;
    return true;
}

/// On an error the caller still owns `first`; after that the tab does.
fn addTab(self: *BrowserPanel, first: BrowserTab.First) error{ Full, OutOfMemory }!u32 {
    if (self.tab_count == data.max_tabs) return error.Full;
    const tab = try alloc.create(BrowserTab);
    tab.* = .{ .id = self.next_id, .first = first };
    self.next_id += 1;
    self.tab_slots[self.tab_count] = tab;
    self.tab_count += 1;
    self.select(self.tab_count - 1);
    if (self.environment != null and !browser_engine.createPage(self, tab)) self.closeTab(tab);
    return tab.id;
}

pub fn closeTab(self: *BrowserPanel, tab: *BrowserTab) void {
    const index = self.indexOf(tab) orelse return;
    tab.deinit();
    alloc.destroy(tab);
    std.mem.copyForwards(*BrowserTab, self.tab_slots[index .. self.tab_count - 1], self.tab_slots[index + 1 .. self.tab_count]);
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.active = 0;
        if (w32.GetParent(self.hwnd)) |parent| _ = w32.PostMessageW(parent, message_empty, 0, 0);
    } else {
        if (index < self.active or self.active == self.tab_count) self.active -= 1;
        self.select(self.active);
    }
    self.invalidateToolbar();
}

/// Show tab `index`, hiding the others.
pub fn select(self: *BrowserPanel, index: usize) void {
    if (index >= self.tab_count) return;
    self.active = index;
    for (self.tabs(), 0..) |tab, i| tab.show(i == index and self.shown and tab.ready);
    if (self.address.focused) self.address.focus(self.hwnd, false);
    self.showSource();
    self.invalidateToolbar();
}

/// A tab finished preparing its page and may show.
pub fn tabReady(self: *BrowserPanel, tab: *BrowserTab) void {
    if (self.activeTab() == tab) tab.show(self.shown);
    self.tabChanged(tab);
}

/// A tab's address, title or history changed.
pub fn tabChanged(self: *BrowserPanel, tab: *BrowserTab) void {
    if (self.activeTab() == tab and !self.address.focused) self.showSource();
    self.invalidateToolbar();
}

pub fn showSource(self: *BrowserPanel) void {
    var buf: [2048]u8 = undefined;
    const tab = self.activeTab() orelse return self.address.clear();
    self.address.set(tab.source(&buf) orelse "");
}

// ---- Layout ------------------------------------------------------------

/// Follow the parent's layout, scale, colors and search engine.
pub fn place(self: *BrowserPanel, rect: w32.RECT, scale: f32, palette: tab_strip.Palette, engine: *const Engine) void {
    self.palette = palette;
    self.engine = engine;
    if (scale != self.scale) {
        self.scale = scale;
        self.initFonts();
    }
    _ = w32.SetWindowPos(self.hwnd, null, rect.left, rect.top, @max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1), w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    for (self.tabs()) |tab| self.placeTab(tab);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Where pages show: the fixed layout size scaled to fit below the
/// toolbar, centered both ways.
fn pageRect(self: *const BrowserPanel) struct { w32.RECT, f64 } {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &client);
    const bar = self.toolbarLayout();
    const left = bar.gripWidth();
    const top = bar.height();
    const width: f64 = @floatFromInt(@max(1, client.right - left));
    const height: f64 = @floatFromInt(@max(1, client.bottom - top));
    const vw: f64 = @floatFromInt(data.viewport_width);
    const vh: f64 = @floatFromInt(data.viewport_height);
    const fit = @min(width / vw, height / vh);
    const w: i32 = @intFromFloat(@max(1, @round(vw * fit)));
    const h: i32 = @intFromFloat(@max(1, @round(vh * fit)));
    const x = left + @divTrunc(@as(i32, @intFromFloat(width)) - w, 2);
    const y = top + @divTrunc(@as(i32, @intFromFloat(height)) - h, 2);
    // The page renders in device-independent pixels, scale times larger.
    return .{ .{ .left = x, .top = y, .right = x + w, .bottom = y + h }, @as(f64, @floatFromInt(w)) / self.scale / vw };
}

pub fn placeTab(self: *BrowserPanel, tab: *BrowserTab) void {
    const rect, const zoom = self.pageRect();
    const handler = browser_engine.Ignore.create(0) orelse return;
    defer _ = handler.release();
    tab.place(rect, zoom, .{ data.viewport_width, data.viewport_height }, handler);
}

/// Hidden panels keep their pages but tell WebView2, which then stops
/// rendering them. Showing a panel whose tabs were all closed opens one.
pub fn show(self: *BrowserPanel, shown: bool) void {
    self.shown = shown;
    _ = w32.ShowWindow(self.hwnd, if (shown) w32.SW_SHOW else w32.SW_HIDE);
    if (shown and self.tab_count == 0) {
        _ = self.openTab(self.engine.home);
        return;
    }
    self.select(self.active);
}

/// The parent window moved, which WebView2 needs to place its popups.
pub fn parentMoved(self: *BrowserPanel) void {
    for (self.tabs()) |tab| if (tab.controller) |c| {
        _ = c.vtable.NotifyParentWindowPositionChanged(c);
    };
}

/// Go to `typed` in the active tab.
pub fn navigate(self: *BrowserPanel, typed: []const u8) void {
    const tab = self.activeTab() orelse return;
    var buf: [2048]u8 = undefined;
    tab.navigate(browser_settings.addressFor(std.mem.trim(u8, typed, " \t"), self.engine.search, &buf) orelse return);
}

// ---- Toolbar and input -------------------------------------------------

pub fn toolbarLayout(self: *const BrowserPanel) toolbar.Layout {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &client);
    return .{ .scale = self.scale, .width = client.right, .tab_count = self.tab_count };
}

fn toolbarView(self: *BrowserPanel, titles: *[data.max_tabs][]const u8) toolbar.View {
    for (self.tabs(), 0..) |tab, i| titles[i] = if (tab.title_len > 0) tab.title() else data.untitled;
    const active = self.activeTab();
    return .{
        .palette = self.palette,
        .fonts = self.fonts,
        .titles = titles[0..self.tab_count],
        .active = self.active,
        .address = &self.address,
        .placeholder = data.address_placeholder,
        .hover = self.hover,
        .pressed = self.pressed,
        .can_back = if (active) |t| t.can_back else false,
        .can_forward = if (active) |t| t.can_forward else false,
        .ready = if (active) |t| t.ready else false,
        .can_add = self.tab_count < data.max_tabs,
    };
}

pub fn enabled(self: *BrowserPanel, target: Target) bool {
    var titles: [data.max_tabs][]const u8 = undefined;
    return self.toolbarView(&titles).enabled(target);
}

pub fn invalidateToolbar(self: *BrowserPanel) void {
    var rect: w32.RECT = .{ .left = 0, .top = 0, .right = 100000, .bottom = self.toolbarLayout().height() };
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
    const height = bar.height();
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
    toolbar.paint(c, bar, self.toolbarView(&titles));
    _ = w32.BitBlt(hdc, 0, 0, width, height, mem_dc, 0, 0, w32.SRCCOPY);

    if (self.failed) {
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
        const old_font = w32.SelectObject(hdc, self.fonts.title);
        defer _ = w32.SelectObject(hdc, old_font);
        _ = w32.SetTextColor(hdc, self.palette.text_dim.ref());
        var wide: [256]u16 = undefined;
        const len = wide_string.fromUtf8(&wide, data.unavailable);
        _ = w32.DrawTextW(hdc, @ptrCast(&wide), @intCast(len), &below, w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE);
    }
}
