//! The browser panel beside the terminal: a child window with a toolbar
//! Sharp draws (back, forward, reload, address) over a WebView2 page.
//! A window creates it the first time its globe is clicked, and only while
//! Settings > AI > Tools > Browser is on, so otherwise no browser loads.
const BrowserPanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const SearchField = @import("SearchField.zig");
const browser_log = @import("browser_log.zig");
const toolbar = @import("browser_toolbar.zig");

const log = std.log.scoped(.win32);

pub const Data = struct {
    width_percent: u8,
    min_width: f32,
    home: []const u8,
    search: []const u8,
    address_placeholder: []const u8,
    unavailable: []const u8,
};

pub const data: Data = @import("browser.zon");

comptime {
    if (data.width_percent < 10 or data.width_percent > 80)
        @compileError("browser.zon: width_percent must be between 10 and 80");
}

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Browser");
var class_atom: u16 = 0;

const Target = toolbar.Target;

hwnd: w32.HWND,
scale: f32,
palette: tab_strip.Palette,
fonts: tab_strip.Fonts = .{},
controller: ?*webview2.Controller = null,
webview: ?*webview2.WebView = null,
/// WebView2 could not start, so the panel says why instead.
failed: bool = false,
shown: bool = true,
/// Shows the page's address, or what is being typed while focused.
address: SearchField = .{},
can_back: bool = false,
can_forward: bool = false,
hover: Target = .none,
pressed: Target = .none,
tracking_mouse: bool = false,
/// What the page reported, for Claude's browser_logs.
page_log: browser_log.Log = .{},

/// Create the panel over `rect` (the parent's client pixels) and start
/// WebView2, which arrives later through onController.
pub fn create(alloc: Allocator, instance: w32.HINSTANCE, parent: w32.HWND, rect: w32.RECT, scale: f32, palette: tab_strip.Palette) !*BrowserPanel {
    if (class_atom == 0) {
        class_atom = w32.RegisterClassExW(&.{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
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
    self.* = .{ .hwnd = hwnd, .scale = scale, .palette = palette };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.initFonts();
    self.address.set(data.home);
    self.startWebView();
    return self;
}

pub fn destroy(self: *BrowserPanel, alloc: Allocator) void {
    if (self.controller) |c| _ = c.vtable.Close(c);
    if (self.webview) |v| v.release();
    if (self.controller) |c| c.release();
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.fonts.deinit();
    alloc.destroy(self);
}

/// The panel behind a handler's context, its window, or null once it is
/// gone: WebView2 may call back after the window closed.
fn fromContext(context: usize) ?*BrowserPanel {
    return fromHwnd(@ptrFromInt(context));
}

fn fromHwnd(hwnd: w32.HWND) ?*BrowserPanel {
    if (@as(u16, @truncate(w32.GetClassLongW(hwnd, w32.GCW_ATOM))) != class_atom) return null;
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

/// Follow the parent's layout, scale and colors.
pub fn place(self: *BrowserPanel, rect: w32.RECT, scale: f32, palette: tab_strip.Palette) void {
    self.palette = palette;
    if (scale != self.scale) {
        self.scale = scale;
        self.initFonts();
    }
    _ = w32.SetWindowPos(self.hwnd, null, rect.left, rect.top, @max(rect.right - rect.left, 1), @max(rect.bottom - rect.top, 1), w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    self.placePage();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Hidden panels keep their page but tell WebView2, which then stops
/// rendering it.
pub fn show(self: *BrowserPanel, shown: bool) void {
    self.shown = shown;
    _ = w32.ShowWindow(self.hwnd, if (shown) w32.SW_SHOW else w32.SW_HIDE);
    if (self.controller) |c| _ = c.vtable.put_IsVisible(c, @intFromBool(shown));
}

/// The parent window moved, which WebView2 needs to place its popups.
pub fn parentMoved(self: *BrowserPanel) void {
    if (self.controller) |c| _ = c.vtable.NotifyParentWindowPositionChanged(c);
}

fn placePage(self: *BrowserPanel) void {
    const c = self.controller orelse return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &client) == 0) return;
    // One pixel on the left stays the panel's, as the line beside the terminal.
    _ = c.vtable.put_Bounds(c, .{ .left = @max(1, self.px(1)), .top = self.toolbarLayout().height(), .right = client.right, .bottom = client.bottom });
}

// ---- WebView2 ----------------------------------------------------------

const EnvironmentDone = webview2.Handler(webview2.iid_environment_completed, w32.HRESULT, ?*webview2.Environment, onEnvironment);
const ControllerDone = webview2.Handler(webview2.iid_controller_completed, w32.HRESULT, ?*webview2.Controller, onController);
const SourceChanged = webview2.Handler(webview2.iid_source_changed, *webview2.WebView, ?*anyopaque, onSourceChanged);
const HistoryChanged = webview2.Handler(webview2.iid_history_changed, *webview2.WebView, ?*anyopaque, onHistoryChanged);
const NewWindow = webview2.Handler(webview2.iid_new_window, *webview2.WebView, *webview2.NewWindowArgs, onNewWindow);
const IgnoreDevtools = webview2.Handler(webview2.iid_cdp_completed, w32.HRESULT, ?[*:0]const u16, ignoreDevtools);

fn LogEvent(comptime event: browser_log.Event) type {
    return webview2.Handler(webview2.iid_cdp_event, *webview2.WebView, *webview2.EventArgs, struct {
        fn f(context: usize, _: *webview2.WebView, args: *webview2.EventArgs) void {
            const self = fromContext(context) orelse return;
            var json: ?[*:0]u16 = null;
            if (args.vtable.get_ParameterObjectAsJson(args, &json) < 0) return;
            defer w32.CoTaskMemFree(json);
            const alloc = std.heap.smp_allocator;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json orelse return)) catch return;
            defer alloc.free(utf8);
            self.page_log.addEvent(alloc, w32.GetTickCount64(), event, utf8);
        }
    }.f);
}

/// The DevTools events the page's log listens to.
const log_events = [_]struct { [:0]const u16, browser_log.Event }{
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Runtime.consoleAPICalled"), .console },
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Runtime.exceptionThrown"), .exception },
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Log.entryAdded"), .browser },
};

fn startWebView(self: *BrowserPanel) void {
    // WebView2 runs its callbacks through this thread's message loop.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    var folder: [1024]u16 = undefined;
    const handler = EnvironmentDone.create(@intFromPtr(self.hwnd)) orelse return self.fail();
    defer _ = handler.release();
    webview2.createEnvironment(userDataFolder(&folder) orelse return self.fail(), handler) catch |err| {
        log.warn("browser panel could not start WebView2: {}", .{err});
        return self.fail();
    };
}

/// %LOCALAPPDATA%\Sharp\Browser: the panel's cookies, logins and cache,
/// kept between runs and apart from Edge's own.
fn userDataFolder(out: *[1024]u16) ?[*:0]const u16 {
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\" ++ brand.name ++ "\\Browser");
    const len = w32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), out, out.len);
    if (len == 0 or len + suffix.len + 1 > out.len) return null;
    @memcpy(out[len..][0..suffix.len], suffix);
    out[len + suffix.len] = 0;
    return @ptrCast(out);
}

fn fail(self: *BrowserPanel) void {
    self.failed = true;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn onEnvironment(context: usize, result: w32.HRESULT, environment: ?*webview2.Environment) void {
    const self = fromContext(context) orelse return;
    const env = environment orelse return self.fail();
    if (result < 0) return self.fail();
    const handler = ControllerDone.create(context) orelse return self.fail();
    defer _ = handler.release();
    if (env.vtable.CreateCoreWebView2Controller(env, self.hwnd, handler) < 0) self.fail();
}

fn onController(context: usize, result: w32.HRESULT, created: ?*webview2.Controller) void {
    // When the panel is gone, not taking a reference lets WebView2 drop it.
    const self = fromContext(context) orelse return;
    const controller = created orelse return self.fail();
    if (result < 0) return self.fail();
    var view: ?*webview2.WebView = null;
    if (controller.vtable.get_CoreWebView2(controller, &view) < 0) return self.fail();
    const webview = view orelse return self.fail();
    _ = controller.vtable.AddRef(controller);
    self.controller = controller;
    self.webview = webview;

    var token: webview2.Token = undefined;
    if (SourceChanged.create(context)) |h| {
        _ = webview.vtable.add_SourceChanged(webview, h, &token);
        _ = h.release();
    }
    if (HistoryChanged.create(context)) |h| {
        _ = webview.vtable.add_HistoryChanged(webview, h, &token);
        _ = h.release();
    }
    if (NewWindow.create(context)) |h| {
        _ = webview.vtable.add_NewWindowRequested(webview, h, &token);
        _ = h.release();
    }
    self.listenToLog(context);
    self.placePage();
    _ = controller.vtable.put_IsVisible(controller, @intFromBool(self.shown));
    self.navigate(data.home);
}

fn onSourceChanged(context: usize, webview: *webview2.WebView, _: ?*anyopaque) void {
    const self = fromContext(context) orelse return;
    if (self.address.focused) return;
    self.showSource(webview);
}

fn onHistoryChanged(context: usize, webview: *webview2.WebView, _: ?*anyopaque) void {
    const self = fromContext(context) orelse return;
    var back: c_int = 0;
    var forward: c_int = 0;
    _ = webview.vtable.get_CanGoBack(webview, &back);
    _ = webview.vtable.get_CanGoForward(webview, &forward);
    self.can_back = back != 0;
    self.can_forward = forward != 0;
    self.invalidateToolbar();
}

/// Links that would open a window open in the panel instead, which has
/// no tabs.
fn onNewWindow(context: usize, webview: *webview2.WebView, args: *webview2.NewWindowArgs) void {
    if (fromContext(context) == null) return;
    var uri: ?[*:0]u16 = null;
    if (args.vtable.get_Uri(args, &uri) < 0) return;
    defer w32.CoTaskMemFree(uri);
    _ = args.vtable.put_Handled(args, 1);
    _ = webview.vtable.Navigate(webview, uri orelse return);
}

/// Record the page's console, errors and failed loads from the start, so
/// Claude can read what happened before it asked.
fn listenToLog(self: *BrowserPanel, context: usize) void {
    const webview = self.webview orelse return;
    inline for (log_events) |entry| {
        const name, const event = entry;
        var receiver: ?*webview2.EventReceiver = null;
        if (webview.vtable.GetDevToolsProtocolEventReceiver(webview, name, &receiver) >= 0) {
            if (receiver) |r| {
                defer r.release();
                if (LogEvent(event).create(context)) |h| {
                    var token: webview2.Token = undefined;
                    _ = r.vtable.add_DevToolsProtocolEventReceived(r, h, &token);
                    _ = h.release();
                }
            }
        }
    }
    for ([_][]const u8{ "Runtime.enable", "Log.enable" }) |method| {
        const handler = IgnoreDevtools.create(0) orelse return;
        defer _ = handler.release();
        _ = self.devtools(method, "{}", handler);
    }
}

fn ignoreDevtools(_: usize, _: w32.HRESULT, _: ?[*:0]const u16) void {}

/// Call a DevTools Protocol method; `handler` gets its answer. False when
/// the page isn't ready, and then the handler is never called.
pub fn devtools(self: *BrowserPanel, method: []const u8, params: []const u8, handler: *anyopaque) bool {
    const webview = self.webview orelse return false;
    const alloc = std.heap.smp_allocator;
    const method_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, method) catch return false;
    defer alloc.free(method_w);
    const params_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, params) catch return false;
    defer alloc.free(params_w);
    return webview.vtable.CallDevToolsProtocolMethod(webview, method_w, params_w, handler) >= 0;
}

/// Put the page's address in the address box.
fn showSource(self: *BrowserPanel, webview: *webview2.WebView) void {
    var uri: ?[*:0]u16 = null;
    if (webview.vtable.get_Source(webview, &uri) < 0) return;
    defer w32.CoTaskMemFree(uri);
    var utf8: [2048]u8 = undefined;
    const len = wide_string.toUtf8(&utf8, std.mem.span(uri orelse return));
    self.address.set(utf8[0..len]);
    self.invalidateToolbar();
}

/// Go to `typed`: an address, with or without its scheme, or words to
/// search for.
pub fn navigate(self: *BrowserPanel, typed: []const u8) void {
    const webview = self.webview orelse return;
    var buf: [2048]u8 = undefined;
    const url = addressFor(std.mem.trim(u8, typed, " \t"), &buf) orelse return;
    var wide: [2048]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, url);
    _ = webview.vtable.Navigate(webview, @ptrCast(&wide));
}

/// The page an address box (or Claude) means by `typed`.
pub fn addressFor(typed: []const u8, out: []u8) ?[]const u8 {
    if (typed.len == 0) return null;
    var w: std.Io.Writer = .fixed(out);
    const has_scheme = std.mem.indexOf(u8, typed, "://") != null or
        std.mem.startsWith(u8, typed, "about:") or std.mem.startsWith(u8, typed, "data:");
    const looks_like_host = std.mem.indexOfScalar(u8, typed, ' ') == null and
        (std.mem.indexOfScalar(u8, typed, '.') != null or std.mem.startsWith(u8, typed, "localhost"));
    if (has_scheme) {
        w.writeAll(typed) catch return null;
    } else if (looks_like_host) {
        // Local servers rarely have certificates.
        const local = std.mem.startsWith(u8, typed, "localhost") or std.mem.startsWith(u8, typed, "127.0.0.1");
        w.print("{s}{s}", .{ if (local) "http://" else "https://", typed }) catch return null;
    } else {
        w.writeAll(data.search) catch return null;
        for (typed) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                w.writeByte(c) catch return null;
            } else if (c == ' ') {
                w.writeByte('+') catch return null;
            } else {
                w.print("%{X:0>2}", .{c}) catch return null;
            }
        }
    }
    return w.buffered();
}

// ---- Toolbar -----------------------------------------------------------

fn toolbarLayout(self: *const BrowserPanel) toolbar.Layout {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &client);
    return .{ .scale = self.scale, .width = client.right };
}

fn toolbarView(self: *const BrowserPanel) toolbar.View {
    return .{
        .palette = self.palette,
        .fonts = self.fonts,
        .address = &self.address,
        .placeholder = data.address_placeholder,
        .hover = self.hover,
        .pressed = self.pressed,
        .can_back = self.can_back,
        .can_forward = self.can_forward,
        .ready = self.webview != null,
    };
}

fn enabled(self: *const BrowserPanel, target: Target) bool {
    return self.toolbarView().enabled(target);
}

fn invalidateToolbar(self: *BrowserPanel) void {
    var rect: w32.RECT = .{ .left = 0, .top = 0, .right = 100000, .bottom = self.toolbarLayout().height() };
    _ = w32.InvalidateRect(self.hwnd, &rect, 0);
}

fn setHover(self: *BrowserPanel, target: Target) void {
    if (target == self.hover) return;
    self.hover = target;
    self.invalidateToolbar();
}

fn act(self: *BrowserPanel, target: Target) void {
    const webview = self.webview orelse return;
    switch (target) {
        .back => _ = webview.vtable.GoBack(webview),
        .forward => _ = webview.vtable.GoForward(webview),
        .reload => _ = webview.vtable.Reload(webview),
        .address, .none => {},
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
    if (self.webview) |v| self.showSource(v);
    self.invalidateToolbar();
}

fn paint(self: *BrowserPanel) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(self.hwnd, &ps);
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &client) == 0) return;
    const bar = self.toolbarLayout();
    const width = bar.width;
    const height = bar.height();
    if (width <= 0) return;

    // Until the page shows, and when it can't, the area below is the
    // terminal's color; the page covers it otherwise.
    var below: w32.RECT = .{ .left = 0, .top = height, .right = width, .bottom = client.bottom };
    if (w32.CreateSolidBrush(self.palette.active_tab.ref())) |brush| {
        _ = w32.FillRect(hdc, &below, brush);
        _ = w32.DeleteObject(brush);
    }
    if (w32.CreateSolidBrush(self.palette.separator.ref())) |brush| {
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
    toolbar.paint(c, bar, self.toolbarView());
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

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    switch (msg) {
        w32.WM_PAINT => {
            self.paint();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            self.placePage();
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            if (!self.tracking_mouse) {
                var tme = w32.TRACKMOUSEEVENT{ .cbSize = @sizeOf(w32.TRACKMOUSEEVENT), .dwFlags = w32.TME_LEAVE, .hwndTrack = hwnd, .dwHoverTime = 0 };
                _ = w32.TrackMouseEvent(&tme);
                self.tracking_mouse = true;
            }
            const target = self.toolbarLayout().hit(x, y);
            self.setHover(if (self.enabled(target)) target else .none);
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.setHover(.none);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            const target = self.toolbarLayout().hit(x, y);
            if (!self.enabled(target)) return 0;
            if (target == .address) {
                if (!self.address.focused) self.editAddress();
                return 0;
            }
            self.stopEditing();
            self.pressed = target;
            _ = w32.SetCapture(hwnd);
            self.invalidateToolbar();
            return 0;
        },
        w32.WM_LBUTTONUP => {
            const pressed = self.pressed;
            if (pressed == .none) return 0;
            self.pressed = .none;
            _ = w32.ReleaseCapture();
            if (self.toolbarLayout().hit(x, y) == pressed) self.act(pressed);
            self.invalidateToolbar();
            return 0;
        },
        w32.WM_SETCURSOR => {
            if ((lparam & 0xFFFF) == w32.HTCLIENT and self.hover == .address) {
                _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_IBEAM));
                return 1;
            }
        },
        w32.WM_KEYDOWN => {
            if (!self.address.focused) return 0;
            const vk: u16 = @truncate(wparam);
            switch (vk) {
                w32.VK_RETURN => {
                    self.address.focus(hwnd, false);
                    self.navigate(self.address.text());
                    if (self.controller) |c| _ = c.vtable.MoveFocus(c, webview2.Controller.focus_programmatic);
                    self.invalidateToolbar();
                },
                w32.VK_ESCAPE => self.stopEditing(),
                else => if (self.address.key(hwnd, vk)) self.invalidateToolbar(),
            }
            return 0;
        },
        w32.WM_CHAR => {
            if (self.address.focused and self.address.typeChar(@truncate(wparam))) self.invalidateToolbar();
            return 0;
        },
        w32.WM_KILLFOCUS => {
            self.stopEditing();
            return 0;
        },
        w32.WM_TIMER => {
            if (wparam == SearchField.caret_timer) {
                self.address.blink();
                self.invalidateToolbar();
            }
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
