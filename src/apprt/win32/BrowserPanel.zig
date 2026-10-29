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
const browser_chats = @import("browser_chats.zig");
const dialog_bar = @import("browser_dialog_bar.zig");
const browser_cover = @import("browser_cover.zig");
const panel_view = @import("browser_panel_view.zig");

const Owner = browser_chats.Owner;

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
pub const message_expand: u32 = w32.WM_APP + 23;
pub const message_pages: u32 = w32.WM_APP + 24;
pub const message_restart: u32 = w32.WM_APP + 25;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Browser");
var class_atom: u16 = 0;

const Target = toolbar.Target;

hwnd: w32.HWND,
instance: w32.HINSTANCE,
scale: f32,
palette: tab_strip.Palette,
fonts: tab_strip.Fonts = .{},
engine: *const Engine,
environment: ?*webview2.Environment = null,
tab_slots: [data.max_total_tabs]*BrowserTab = undefined,
tab_count: usize = 0,
owner: Owner,
stamp: u64 = 0,
next_id: u32 = 1,
/// WebView2 could not start, so the panel says why instead.
failed: bool = false,
shown: bool = true,
/// Shows the active page's address, or what is being typed.
address: SearchField = .{},
dialog_field: SearchField = .{},
cover: browser_cover.Cover = .{},
expanded: bool = false,
hover: Target = .none,
pressed: Target = .none,
tracking_mouse: bool = false,
resizing: bool = false,

pub fn create(instance: w32.HINSTANCE, parent: w32.HWND, rect: w32.RECT, scale: f32, palette: tab_strip.Palette, engine: *const Engine, owner: Owner, shown: bool) !*BrowserPanel {
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
        w32.WS_CHILD | w32.WS_CLIPCHILDREN | if (shown) w32.WS_VISIBLE_STYLE else 0,
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
    self.* = .{ .hwnd = hwnd, .instance = instance, .scale = scale, .palette = palette, .engine = engine, .owner = owner, .shown = shown };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.initFonts();
    browser_engine.start(self);
    return self;
}

pub fn destroy(self: *BrowserPanel) void {
    for (self.tabs()) |tab| {
        tab.deinit();
        alloc.destroy(tab);
    }
    self.tab_count = 0;
    self.cover.hide();
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

pub fn px(self: *const BrowserPanel, value: f32) i32 {
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

pub const OwnTabs = [data.max_tabs]*BrowserTab;

pub fn ownTabs(self: *BrowserPanel, owner: Owner, out: *OwnTabs) []*BrowserTab {
    var n: usize = 0;
    for (self.tabs()) |tab| {
        if (tab.owner != owner or n == out.len) continue;
        out[n] = tab;
        n += 1;
    }
    return out[0..n];
}

pub fn shownTabs(self: *BrowserPanel, out: *OwnTabs) []*BrowserTab {
    return self.ownTabs(self.owner, out);
}

pub fn tabById(self: *BrowserPanel, id: u32) ?*BrowserTab {
    for (self.tabs()) |tab| if (tab.id == id) return tab;
    return null;
}

pub fn ownTab(self: *BrowserPanel, owner: Owner, id: u32) ?*BrowserTab {
    const tab = self.tabById(id) orelse return null;
    return if (tab.owner == owner) tab else null;
}

pub fn activeOf(self: *BrowserPanel, owner: Owner) ?*BrowserTab {
    var best: ?*BrowserTab = null;
    for (self.tabs()) |tab| {
        if (tab.owner != owner) continue;
        if (best == null or tab.selected_at > best.?.selected_at) best = tab;
    }
    return best;
}

pub fn activeTab(self: *BrowserPanel) ?*BrowserTab {
    return self.activeOf(self.owner);
}

fn indexOf(self: *BrowserPanel, tab: *const BrowserTab) ?usize {
    for (self.tabs(), 0..) |t, i| if (t == tab) return i;
    return null;
}

pub fn openTab(self: *BrowserPanel, owner: Owner, url: []const u8) ?u32 {
    const owned = alloc.dupe(u8, url) catch return null;
    return self.addTab(owner, .{ .url = owned }) catch {
        alloc.free(owned);
        return null;
    };
}

/// A page opened a window: make it a tab. False when no more tabs fit,
/// and then the caller keeps what it passed.
pub fn openPopup(self: *BrowserPanel, owner: Owner, args: *webview2.NewWindowArgs, deferral: *webview2.Deferral) bool {
    _ = self.addTab(owner, .{ .popup = .{ .args = args, .deferral = deferral } }) catch return false;
    return true;
}

pub fn hasRoom(self: *BrowserPanel, owner: Owner) bool {
    var own: OwnTabs = undefined;
    return self.tab_count < data.max_total_tabs and self.ownTabs(owner, &own).len < data.max_tabs;
}

/// On an error the caller still owns `first`; after that the tab does.
fn addTab(self: *BrowserPanel, owner: Owner, first: BrowserTab.First) error{ Full, OutOfMemory }!u32 {
    if (!self.hasRoom(owner)) return error.Full;
    const tab = try alloc.create(BrowserTab);
    tab.* = .{ .id = self.next_id, .owner = owner, .first = first };
    self.next_id += 1;
    self.tab_slots[self.tab_count] = tab;
    self.tab_count += 1;
    self.select(tab);
    if (self.environment != null and !browser_engine.createPage(self, tab)) self.closeTab(tab);
    return tab.id;
}

pub fn closeTab(self: *BrowserPanel, tab: *BrowserTab) void {
    const index = self.indexOf(tab) orelse return;
    const owner = tab.owner;
    tab.deinit();
    alloc.destroy(tab);
    std.mem.copyForwards(*BrowserTab, self.tab_slots[index .. self.tab_count - 1], self.tab_slots[index + 1 .. self.tab_count]);
    self.tab_count -= 1;
    if (owner == self.owner and self.activeTab() == null) {
        if (w32.GetParent(self.hwnd)) |parent| _ = w32.PostMessageW(parent, message_empty, 0, 0);
    }
    self.pagesChanged();
    self.refresh();
    if (owner == self.owner) self.frontChanged();
}

pub fn closeOwner(self: *BrowserPanel, owner: Owner) void {
    var own: OwnTabs = undefined;
    for (self.ownTabs(owner, &own)) |tab| self.closeTab(tab);
}

pub fn select(self: *BrowserPanel, tab: *BrowserTab) void {
    self.stamp += 1;
    tab.selected_at = self.stamp;
    if (tab.owner != self.owner) return;
    self.refresh();
    self.frontChanged();
}

pub fn showOwner(self: *BrowserPanel, owner: Owner) void {
    if (owner == self.owner) return;
    self.owner = owner;
    self.refresh();
    self.frontChanged();
}

pub fn park(self: *BrowserPanel, tab: *BrowserTab, parked: bool) void {
    if (tab.parked == parked) return;
    tab.parked = parked;
    self.refresh();
}

pub fn inSight(self: *BrowserPanel, tab: *const BrowserTab) bool {
    return self.shown and tab.owner == self.owner and self.activeTab() == tab;
}

pub fn refresh(self: *BrowserPanel) void {
    for (self.tabs()) |tab| {
        if (self.inSight(tab) != tab.on_screen) self.placeTab(tab);
        tab.show(tab.ready and (tab.on_screen or tab.parked));
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn frontChanged(self: *BrowserPanel) void {
    if (self.address.focused) self.address.focus(self.hwnd, false);
    if (self.dialog_field.focused) self.dialog_field.focus(self.hwnd, false);
    self.showSource();
    const tab = self.activeTab() orelse return;
    if (tab.dialog) |d| self.dialog_field.set(d.defaultText());
    self.placeTab(tab);
}

pub fn dialogLayout(self: *BrowserPanel) ?dialog_bar.Layout {
    const tab = self.activeTab() orelse return null;
    const dialog = tab.dialog orelse return null;
    const bar = self.toolbarLayout();
    return .{ .scale = self.scale, .left = bar.gripWidth(), .top = bar.height(), .width = bar.width, .kind = dialog.kind };
}

pub fn dialogHeight(self: *BrowserPanel) i32 {
    return if (self.dialogLayout() != null) dialog_bar.Layout.height(self.scale) else 0;
}

pub fn dialogChanged(self: *BrowserPanel, tab: *BrowserTab) void {
    if (self.activeTab() != tab) return;
    const dialog = tab.dialog orelse return;
    self.dialog_field.set(dialog.defaultText());
    self.placeTab(tab);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

pub fn answerDialog(self: *BrowserPanel, tab: *BrowserTab, accept: bool, text: []const u8) void {
    tab.answerDialog(accept, text);
    if (self.activeTab() != tab) return;
    if (self.dialog_field.focused) self.dialog_field.focus(self.hwnd, false);
    self.placeTab(tab);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

pub fn pagesChanged(self: *BrowserPanel) void {
    if (w32.GetParent(self.hwnd)) |parent| _ = w32.PostMessageW(parent, message_pages, 0, 0);
}

/// A tab finished preparing its page and may show.
pub fn tabReady(self: *BrowserPanel, tab: *BrowserTab) void {
    tab.show(self.inSight(tab) or tab.parked);
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
fn pageRect(self: *BrowserPanel, tab: *const BrowserTab) struct { w32.RECT, f64 } {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &client);
    const bar = self.toolbarLayout();
    const left = bar.gripWidth();
    const top = bar.height() + self.dialogHeight();
    const width: f64 = @floatFromInt(@max(1, client.right - left));
    const height: f64 = @floatFromInt(@max(1, client.bottom - top));
    const vw: f64 = @floatFromInt(tab.viewport[0]);
    const vh: f64 = @floatFromInt(tab.viewport[1]);
    const fit = @min(width / vw, height / vh);
    const w: i32 = @intFromFloat(@max(1, @round(vw * fit)));
    const h: i32 = @intFromFloat(@max(1, @round(vh * fit)));
    const x = left + @divTrunc(@as(i32, @intFromFloat(width)) - w, 2);
    const y = top + @divTrunc(@as(i32, @intFromFloat(height)) - h, 2);
    // The page renders in device-independent pixels, scale times larger.
    return .{ .{ .left = x, .top = y, .right = x + w, .bottom = y + h }, @as(f64, @floatFromInt(w)) / self.scale / vw };
}

pub fn placeTab(self: *BrowserPanel, tab: *BrowserTab) void {
    var rect, const zoom = self.pageRect(tab);
    tab.on_screen = self.inSight(tab);
    if (!tab.on_screen) {
        const width = rect.right - rect.left;
        rect.left = -100_000;
        rect.right = rect.left + width;
    }
    const handler = browser_engine.Ignore.create(0) orelse return;
    defer _ = handler.release();
    tab.place(rect, zoom, handler);
}

pub fn shownScale(self: *BrowserPanel, tab: *const BrowserTab) f64 {
    const rect, _ = self.pageRect(tab);
    return @as(f64, @floatFromInt(rect.right - rect.left)) / @as(f64, @floatFromInt(@max(1, tab.viewport[0])));
}

pub fn setViewport(self: *BrowserPanel, tab: *BrowserTab, width: u32, height: u32, mobile: ?bool) void {
    tab.viewport = .{ width, height };
    const switching = mobile != null and mobile.? != tab.mobile;
    if (mobile) |m| tab.mobile = m;
    self.placeTab(tab);
    if (switching) browser_engine.setMobile(tab);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

pub fn coverPage(self: *BrowserPanel, tab: *BrowserTab, on: bool) void {
    if (!on) return self.cover.hide();
    if (!self.inSight(tab)) return;
    const rect, _ = self.pageRect(tab);
    self.cover.show(self.instance, self.hwnd, rect);
}

/// Hidden panels keep their pages but tell WebView2, which then stops
/// rendering them. Showing a panel whose tabs were all closed opens one.
pub fn show(self: *BrowserPanel, shown: bool) void {
    self.shown = shown;
    _ = w32.ShowWindow(self.hwnd, if (shown) w32.SW_SHOW else w32.SW_HIDE);
    if (shown and self.activeTab() == null) {
        _ = self.openTab(self.owner, self.engine.home);
        return;
    }
    self.refresh();
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

pub const toolbarLayout = panel_view.toolbarLayout;
pub const enabled = panel_view.enabled;
pub const hit = panel_view.hit;
pub const invalidateToolbar = panel_view.invalidateToolbar;
pub const paint = panel_view.paint;
