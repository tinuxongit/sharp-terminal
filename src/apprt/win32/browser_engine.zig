//! The WebView2 side of the browser panel: the environment (one browser
//! process and profile for the panel), each tab's page, preparing a page
//! so sites see plain Chrome at the fixed desktop size before it loads
//! anything, and turning page events into panel updates.
const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const browser_log = @import("browser_log.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_settings = @import("browser_settings.zig");
const BrowserTab = @import("BrowserTab.zig");
const browser_messages = @import("browser_messages.zig");

const log = std.log.scoped(.win32);
const alloc = std.heap.smp_allocator;

/// Which tab a callback is about. Ids rather than pointers, so a callback
/// arriving after the panel or tab closed finds nothing.
const TabRef = extern struct { hwnd: usize, tab: u32 };

fn find(ref: TabRef) ?struct { *BrowserPanel, *BrowserTab } {
    const panel = BrowserPanel.fromHwnd(@ptrFromInt(ref.hwnd)) orelse return null;
    return .{ panel, panel.tabById(ref.tab) orelse return null };
}

fn refOf(panel: *const BrowserPanel, tab: *const BrowserTab) TabRef {
    return .{ .hwnd = @intFromPtr(panel.hwnd), .tab = tab.id };
}

const EnvironmentDone = webview2.Handler(webview2.iid_environment_completed, usize, w32.HRESULT, ?*webview2.Environment, onEnvironment);
const ControllerDone = webview2.Handler(webview2.iid_controller_completed, TabRef, w32.HRESULT, ?*webview2.Controller, onController);
const IdentityRead = webview2.Handler(webview2.iid_cdp_completed, TabRef, w32.HRESULT, ?[*:0]const u16, onIdentityRead);
const IdentitySet = webview2.Handler(webview2.iid_cdp_completed, TabRef, w32.HRESULT, ?[*:0]const u16, onIdentitySet);
const SourceChanged = webview2.Handler(webview2.iid_source_changed, TabRef, *webview2.WebView, ?*anyopaque, onSourceChanged);
const HistoryChanged = webview2.Handler(webview2.iid_history_changed, TabRef, *webview2.WebView, ?*anyopaque, onHistoryChanged);
const TitleChanged = webview2.Handler(webview2.iid_title_changed, TabRef, *webview2.WebView, ?*anyopaque, onTitleChanged);
const NewWindow = webview2.Handler(webview2.iid_new_window, TabRef, *webview2.WebView, *webview2.NewWindowArgs, onNewWindow);
const KeyPressed = webview2.Handler(webview2.iid_accelerator_key, TabRef, *webview2.Controller, *webview2.KeyArgs, onKeyPressed);
pub const Ignore = webview2.Handler(webview2.iid_cdp_completed, usize, w32.HRESULT, ?[*:0]const u16, ignore);

fn ignore(_: usize, _: w32.HRESULT, _: ?[*:0]const u16) void {}

/// Call a DevTools method on `tab` without waiting for its answer. Calls
/// on one page run in the order made.
pub fn send(tab: *const BrowserTab, method: []const u8, params: []const u8) void {
    const handler = Ignore.create(0) orelse return;
    defer _ = handler.release();
    _ = tab.devtools(method, params, handler);
}

/// Start the panel's browser; its tabs get their pages once it exists.
pub fn start(panel: *BrowserPanel) void {
    // WebView2 runs its callbacks through this thread's message loop.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    var folder: [1024]u16 = undefined;
    const handler = EnvironmentDone.create(@intFromPtr(panel.hwnd)) orelse return panel.fail();
    defer _ = handler.release();
    webview2.createEnvironment(userDataFolder(&folder) orelse return panel.fail(), handler) catch |err| {
        log.warn("browser panel could not start WebView2: {}", .{err});
        return panel.fail();
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

fn onEnvironment(context: usize, result: w32.HRESULT, environment: ?*webview2.Environment) void {
    const panel = BrowserPanel.fromHwnd(@ptrFromInt(context)) orelse return;
    const env = environment orelse return panel.fail();
    if (result < 0) return panel.fail();
    env.addRef();
    panel.environment = env;
    // Closing a tab reorders the list, so work from a copy.
    var waiting: [browser_settings.data.max_tabs]*BrowserTab = undefined;
    const n = panel.tabs().len;
    @memcpy(waiting[0..n], panel.tabs());
    for (waiting[0..n]) |tab| if (!createPage(panel, tab)) panel.closeTab(tab);
}

/// Start creating `tab`'s page, which arrives in onController. Tabs made
/// before the browser started get theirs from onEnvironment.
pub fn createPage(panel: *BrowserPanel, tab: *BrowserTab) bool {
    const env = panel.environment orelse return false;
    const handler = ControllerDone.create(refOf(panel, tab)) orelse return false;
    defer _ = handler.release();
    return env.vtable.CreateCoreWebView2Controller(env, panel.hwnd, handler) >= 0;
}

fn onController(ref: TabRef, result: w32.HRESULT, created: ?*webview2.Controller) void {
    // Without the tab, not taking a reference lets WebView2 drop the page.
    const panel, const tab = find(ref) orelse return;
    const controller = created orelse return panel.closeTab(tab);
    if (result < 0) return panel.closeTab(tab);
    var view: ?*webview2.WebView = null;
    if (controller.vtable.get_CoreWebView2(controller, &view) < 0) return panel.closeTab(tab);
    const webview = view orelse return panel.closeTab(tab);
    controller.addRef();
    tab.controller = controller;
    tab.webview = webview;

    harden(webview);
    listen(ref, controller, webview);
    // Hidden until it has its identity, so nothing shows before then.
    tab.show(false);
    panel.placeTab(tab);
    prepare(ref, tab);
}

/// Nothing in the page may reach Sharp: no host objects or messages, and
/// no zoom, which would break the fixed layout size.
fn harden(webview: *webview2.WebView) void {
    var settings: ?*webview2.Settings = null;
    if (webview.vtable.get_Settings(webview, &settings) < 0) return;
    const s = settings orelse return;
    defer s.release();
    _ = s.vtable.put_IsWebMessageEnabled(s, 0);
    _ = s.vtable.put_AreHostObjectsAllowed(s, 0);
    _ = s.vtable.put_IsZoomControlEnabled(s, 0);
}

fn listen(ref: TabRef, controller: *webview2.Controller, webview: *webview2.WebView) void {
    var token: webview2.Token = undefined;
    if (SourceChanged.create(ref)) |h| {
        _ = webview.vtable.add_SourceChanged(webview, h, &token);
        _ = h.release();
    }
    if (HistoryChanged.create(ref)) |h| {
        _ = webview.vtable.add_HistoryChanged(webview, h, &token);
        _ = h.release();
    }
    if (TitleChanged.create(ref)) |h| {
        _ = webview.vtable.add_DocumentTitleChanged(webview, h, &token);
        _ = h.release();
    }
    if (NewWindow.create(ref)) |h| {
        _ = webview.vtable.add_NewWindowRequested(webview, h, &token);
        _ = h.release();
    }
    if (KeyPressed.create(ref)) |h| {
        _ = controller.vtable.add_AcceleratorKeyPressed(controller, h, &token);
        _ = h.release();
    }
    inline for (log_events) |entry| {
        const name, const event = entry;
        var receiver: ?*webview2.EventReceiver = null;
        if (webview.vtable.GetDevToolsProtocolEventReceiver(webview, name, &receiver) >= 0) {
            if (receiver) |r| {
                defer r.release();
                if (LogEvent(event).create(ref)) |h| {
                    _ = r.vtable.add_DevToolsProtocolEventReceived(r, h, &token);
                    _ = h.release();
                }
            }
        }
    }
}

// ---- Identity ----------------------------------------------------------
//
// WebView2 tells sites it is "Microsoft Edge WebView2", in the user agent
// ("Edg/") and the client hints, and some sites treat it as an embedded
// browser. Each page is told to present itself as the Chrome of the same
// version instead, with the user's Windows language, before it loads.

/// Emulation.setUserAgentOverride's parameters, made once from the first
/// page and kept for every page after.
var identity: ?[]u8 = null;

/// Run in a fresh page: WebView2's own user agent with "Edg/" removed and
/// client hints naming Chrome. A fresh page doesn't expose the hints, so
/// they are built as Chromium builds Chrome's, its "grease" brand
/// included. LANGUAGE and PLATFORM are filled in from Windows.
const identity_script =
    \\(async () => {
    \\  const ua = navigator.userAgent.replace(/ Edg\/[\d.]+/, "");
    \\  const major = Number((ua.match(/Chrome\/(\d+)/) || [])[1] || "0");
    \\  const data = navigator.userAgentData;
    \\  const high = data ? await data.getHighEntropyValues(["platformVersion", "architecture", "bitness", "fullVersionList"]) : {};
    \\  const chars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"];
    \\  const grease = { brand: "Not" + chars[major % 11] + "A" + chars[(major + 1) % 11] + "Brand", version: ["8", "99", "24"][major % 3] };
    \\  const asChrome = (list, full) => {
    \\    if (!list) {
    \\      const v = full ? major + ".0.0.0" : String(major);
    \\      return [{ brand: "Chromium", version: v }, { brand: "Google Chrome", version: v },
    \\        { brand: grease.brand, version: full ? grease.version + ".0.0.0" : grease.version }];
    \\    }
    \\    const out = list.filter((b) => !/Edge/.test(b.brand));
    \\    const chromium = out.find((b) => b.brand === "Chromium") || { version: String(major) };
    \\    out.splice(out.indexOf(chromium) + 1, 0, { brand: "Google Chrome", version: chromium.version });
    \\    return out;
    \\  };
    \\  return {
    \\    userAgent: ua,
    \\    acceptLanguage: LANGUAGE,
    \\    userAgentMetadata: {
    \\      brands: asChrome(data && data.brands, false),
    \\      fullVersionList: asChrome(high.fullVersionList, true),
    \\      platform: "Windows",
    \\      platformVersion: high.platformVersion || PLATFORM,
    \\      architecture: high.architecture || "x86",
    \\      model: "",
    \\      mobile: false,
    \\      bitness: high.bitness || "64",
    \\      wow64: false,
    \\    },
    \\  };
    \\})()
;

fn prepare(ref: TabRef, tab: *BrowserTab) void {
    if (identity) |params| return setIdentity(ref, tab, params);
    const params = identityProbe() orelse return finish(ref);
    defer alloc.free(params);
    const handler = IdentityRead.create(ref) orelse return finish(ref);
    defer _ = handler.release();
    if (!tab.devtools("Runtime.evaluate", params, handler)) finish(ref);
}

/// Runtime.evaluate's parameters for identity_script.
fn identityProbe() ?[]u8 {
    var lang_buf: [200]u8 = undefined;
    var platform_buf: [32]u8 = undefined;
    const with_language = std.mem.replaceOwned(u8, alloc, identity_script, "LANGUAGE", language(&lang_buf) orelse return null) catch return null;
    defer alloc.free(with_language);
    const script = std.mem.replaceOwned(u8, alloc, with_language, "PLATFORM", platformVersion(&platform_buf) orelse return null) catch return null;
    defer alloc.free(script);
    return std.json.Stringify.valueAlloc(alloc, .{ .expression = script, .awaitPromise = true, .returnByValue = true }, .{}) catch null;
}

/// The languages Chrome would send here, quoted: "en-US,en" (Chrome adds
/// the q-values itself).
fn language(out: []u8) ?[]const u8 {
    var locale_w: [85]u16 = undefined;
    const n = w32.GetUserDefaultLocaleName(&locale_w, locale_w.len);
    var locale_buf: [85]u8 = undefined;
    const locale = if (n > 1) locale_buf[0..wide_string.toUtf8(&locale_buf, locale_w[0..@intCast(n - 1)])] else "en-US";
    return if (std.mem.indexOfScalar(u8, locale, '-')) |dash|
        std.fmt.bufPrint(out, "\"{s},{s}\"", .{ locale, locale[0..dash] }) catch null
    else
        std.fmt.bufPrint(out, "\"{s}\"", .{locale}) catch null;
}

/// Windows' version as Chrome reports it, quoted: the Universal API
/// Contract's ("19.0.0" on Windows 11 24H2).
fn platformVersion(out: []u8) ?[]const u8 {
    var key: w32.HKEY = undefined;
    const path = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\WindowsRuntime\\WellKnownContracts");
    if (w32.RegOpenKeyExW(w32.HKEY_LOCAL_MACHINE, path, 0, w32.KEY_READ, &key) != w32.ERROR_SUCCESS) return "\"10.0.0\"";
    defer _ = w32.RegCloseKey(key);
    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Foundation.UniversalApiContract");
    if (w32.RegQueryValueExW(key, name, null, null, @ptrCast(&value), &size) != w32.ERROR_SUCCESS) return "\"10.0.0\"";
    return std.fmt.bufPrint(out, "\"{d}.{d}.0\"", .{ value >> 16, value & 0xFFFF }) catch null;
}

fn onIdentityRead(ref: TabRef, result: w32.HRESULT, json: ?[*:0]const u16) void {
    _, const tab = find(ref) orelse return;
    if (result >= 0 and identity == null) identity = identityFrom(json);
    if (identity) |params| setIdentity(ref, tab, params) else finish(ref);
}

/// The script's value, as the parameters it was written to be.
fn identityFrom(json: ?[*:0]const u16) ?[]u8 {
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json orelse return null)) catch return null;
    defer alloc.free(utf8);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, utf8, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const value = result.object.get("value") orelse return null;
    if (value != .object) return null;
    return std.json.Stringify.valueAlloc(alloc, value, .{}) catch null;
}

fn setIdentity(ref: TabRef, tab: *BrowserTab, params: []const u8) void {
    const handler = IdentitySet.create(ref) orelse return finish(ref);
    defer _ = handler.release();
    if (!tab.devtools("Emulation.setUserAgentOverride", params, handler)) finish(ref);
}

fn onIdentitySet(ref: TabRef, _: w32.HRESULT, _: ?[*:0]const u16) void {
    finish(ref);
}

/// The page is ready: record its log from here on, and load what the tab
/// was opened for.
fn finish(ref: TabRef) void {
    const panel, const tab = find(ref) orelse return;
    send(tab, "Runtime.enable", "{}");
    send(tab, "Log.enable", "{}");
    switch (tab.first) {
        .url => |url| {
            if (url.len > 0) tab.navigate(url);
            alloc.free(url);
        },
        .popup => |p| {
            if (tab.webview) |v| _ = p.args.vtable.put_NewWindow(p.args, v);
            _ = p.deferral.vtable.Complete(p.deferral);
            p.deferral.release();
            p.args.release();
        },
    }
    tab.first = .{ .url = &.{} };
    tab.ready = true;
    panel.tabReady(tab);
}

// ---- Page events -------------------------------------------------------

fn onSourceChanged(ref: TabRef, _: *webview2.WebView, _: ?*anyopaque) void {
    const panel, const tab = find(ref) orelse return;
    panel.tabChanged(tab);
}

fn onHistoryChanged(ref: TabRef, webview: *webview2.WebView, _: ?*anyopaque) void {
    const panel, const tab = find(ref) orelse return;
    var back: c_int = 0;
    var forward: c_int = 0;
    _ = webview.vtable.get_CanGoBack(webview, &back);
    _ = webview.vtable.get_CanGoForward(webview, &forward);
    tab.can_back = back != 0;
    tab.can_forward = forward != 0;
    panel.tabChanged(tab);
}

fn onTitleChanged(ref: TabRef, webview: *webview2.WebView, _: ?*anyopaque) void {
    const panel, const tab = find(ref) orelse return;
    var title: ?[*:0]u16 = null;
    if (webview.vtable.get_DocumentTitle(webview, &title) < 0) return;
    defer w32.CoTaskMemFree(title);
    var buf: [256]u8 = undefined;
    tab.setTitle(buf[0..wide_string.toUtf8(&buf, std.mem.span(title orelse return))]);
    panel.tabChanged(tab);
}

/// A page opening a window gets a new tab for it, as in Chrome.
fn onNewWindow(ref: TabRef, webview: *webview2.WebView, args: *webview2.NewWindowArgs) void {
    const panel, const opener = find(ref) orelse return;
    var deferral: ?*webview2.Deferral = null;
    if (args.vtable.GetDeferral(args, &deferral) >= 0) {
        if (deferral) |d| {
            args.addRef();
            if (panel.openPopup(opener.owner, args, d)) return;
            args.release();
            d.release();
        }
    }
    // No room for another tab: open it in this one.
    var uri: ?[*:0]u16 = null;
    if (args.vtable.get_Uri(args, &uri) < 0) return;
    defer w32.CoTaskMemFree(uri);
    _ = args.vtable.put_Handled(args, 1);
    _ = webview.vtable.Navigate(webview, uri orelse return);
}

fn onKeyPressed(ref: TabRef, _: *webview2.Controller, args: *webview2.KeyArgs) void {
    const panel, _ = find(ref) orelse return;
    var kind: c_int = 0;
    var key: u32 = 0;
    if (args.vtable.get_KeyEventKind(args, &kind) < 0 or args.vtable.get_VirtualKey(args, &key) < 0) return;
    if (kind != webview2.KeyArgs.key_down and kind != webview2.KeyArgs.system_key_down) return;
    if (browser_messages.shortcut(panel, @truncate(key))) _ = args.vtable.put_Handled(args, 1);
}

/// The DevTools events the page's log listens to.
const log_events = [_]struct { [:0]const u16, browser_log.Event }{
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Runtime.consoleAPICalled"), .console },
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Runtime.exceptionThrown"), .exception },
    .{ std.unicode.utf8ToUtf16LeStringLiteral("Log.entryAdded"), .browser },
};

fn LogEvent(comptime event: browser_log.Event) type {
    return webview2.Handler(webview2.iid_cdp_event, TabRef, *webview2.WebView, *webview2.EventArgs, struct {
        fn f(ref: TabRef, _: *webview2.WebView, args: *webview2.EventArgs) void {
            _, const tab = find(ref) orelse return;
            var json: ?[*:0]u16 = null;
            if (args.vtable.get_ParameterObjectAsJson(args, &json) < 0) return;
            defer w32.CoTaskMemFree(json);
            const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json orelse return)) catch return;
            defer alloc.free(utf8);
            tab.page_log.addEvent(alloc, w32.GetTickCount64(), event, utf8);
        }
    }.f);
}
