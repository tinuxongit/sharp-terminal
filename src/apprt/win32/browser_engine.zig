//! The WebView2 side of the browser panel: the environment (one browser
//! process and profile for the panel), each tab's page, preparing a page
//! so sites see plain Chrome at the fixed desktop size before it loads
//! anything, and turning page events into panel updates.
const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_settings = @import("browser_settings.zig");
const BrowserTab = @import("BrowserTab.zig");
const browser_events = @import("browser_events.zig");

const log = std.log.scoped(.win32);
const alloc = std.heap.smp_allocator;

/// Which tab a callback is about. Ids rather than pointers, so a callback
/// arriving after the panel or tab closed finds nothing.
pub const TabRef = extern struct { hwnd: usize, tab: u32 };

pub fn find(ref: TabRef) ?struct { *BrowserPanel, *BrowserTab } {
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
    browser_events.listen(ref, controller, webview);
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
    _ = s.vtable.put_AreDefaultScriptDialogsEnabled(s, 0);
    if (s.as4()) |s4| {
        defer _ = s4.release();
        _ = s4.vtable.put_IsPasswordAutosaveEnabled(s4, 1);
        _ = s4.vtable.put_IsGeneralAutofillEnabled(s4, 1);
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
    browser_events.enableDomains(tab, "");
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
