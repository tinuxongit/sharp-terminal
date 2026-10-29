const std = @import("std");
const w32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const wide_string = @import("wide_string.zig");
const json_read = @import("json_read.zig");
const browser_log = @import("browser_log.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const BrowserTab = @import("BrowserTab.zig");
const browser_engine = @import("browser_engine.zig");
const browser_messages = @import("browser_messages.zig");

const TabRef = browser_engine.TabRef;
const find = browser_engine.find;
const field = json_read.field;
const string = json_read.string;
const alloc = std.heap.smp_allocator;

const SourceChanged = webview2.Handler(webview2.iid_source_changed, TabRef, *webview2.WebView, ?*anyopaque, onSourceChanged);
const HistoryChanged = webview2.Handler(webview2.iid_history_changed, TabRef, *webview2.WebView, ?*anyopaque, onHistoryChanged);
const TitleChanged = webview2.Handler(webview2.iid_title_changed, TabRef, *webview2.WebView, ?*anyopaque, onTitleChanged);
const NewWindow = webview2.Handler(webview2.iid_new_window, TabRef, *webview2.WebView, *webview2.NewWindowArgs, onNewWindow);
const KeyPressed = webview2.Handler(webview2.iid_accelerator_key, TabRef, *webview2.Controller, *webview2.KeyArgs, onKeyPressed);
const ScriptDialog = webview2.Handler(webview2.iid_script_dialog, TabRef, *webview2.WebView, *webview2.ScriptDialogArgs, onScriptDialog);
const DownloadStarting = webview2.Handler(webview2.iid_download_starting, TabRef, *webview2.WebView, *webview2.DownloadStartingArgs, onDownloadStarting);
const DownloadState = webview2.Handler(webview2.iid_download_state, TabRef, *webview2.Download, ?*anyopaque, onDownloadState);

pub fn listen(ref: TabRef, controller: *webview2.Controller, webview: *webview2.WebView) void {
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
    if (ScriptDialog.create(ref)) |h| {
        _ = webview.vtable.add_ScriptDialogOpening(webview, h, &token);
        _ = h.release();
    }
    if (webview.as15()) |v15| {
        defer _ = v15.release();
        if (DownloadStarting.create(ref)) |h| {
            _ = v15.vtable.add_DownloadStarting(v15, h, &token);
            _ = h.release();
        }
    }
    inline for (comptime std.enums.values(Devtools)) |event| {
        var receiver: ?*webview2.EventReceiver = null;
        if (webview.vtable.GetDevToolsProtocolEventReceiver(webview, comptime eventName(event), &receiver) >= 0) {
            if (receiver) |r| {
                defer r.release();
                if (DevtoolsEvent(event).create(ref)) |h| {
                    _ = r.vtable.add_DevToolsProtocolEventReceived(r, h, &token);
                    _ = h.release();
                }
            }
        }
    }
}

pub fn enableDomains(tab: *const BrowserTab, session: []const u8) void {
    sendIn(tab, session, "Runtime.enable", "{}");
    sendIn(tab, session, "Log.enable", "{}");
    sendIn(tab, session, "Network.enable", "{\"maxTotalBufferSize\":0,\"maxResourceBufferSize\":0,\"maxPostDataSize\":0}");
    if (session.len == 0) sendIn(tab, session, "Page.enable", "{}");
    sendIn(tab, session, "Target.setAutoAttach", "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":true}");
}

fn sendIn(tab: *const BrowserTab, session: []const u8, method: []const u8, params: []const u8) void {
    const handler = browser_engine.Ignore.create(0) orelse return;
    defer _ = handler.release();
    _ = tab.devtoolsIn(session, method, params, handler);
}

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

fn onScriptDialog(ref: TabRef, _: *webview2.WebView, args: *webview2.ScriptDialogArgs) void {
    const panel, const tab = find(ref) orelse return;
    if (tab.dialog != null) return;
    var kind: c_int = 0;
    if (args.vtable.get_Kind(args, &kind) < 0) return;
    var deferral: ?*webview2.Deferral = null;
    if (args.vtable.GetDeferral(args, &deferral) < 0) return;
    args.addRef();
    var dialog: BrowserTab.Dialog = .{
        .args = args,
        .deferral = deferral orelse {
            args.release();
            return;
        },
        .kind = std.enums.fromInt(BrowserTab.DialogKind, kind) orelse .alert,
    };
    var message: ?[*:0]u16 = null;
    if (args.vtable.get_Message(args, &message) >= 0) {
        defer w32.CoTaskMemFree(message);
        if (message) |m| dialog.message_len = @intCast(wide_string.toUtf8(&dialog.message_buf, std.mem.span(m)));
    }
    var default_text: ?[*:0]u16 = null;
    if (args.vtable.get_DefaultText(args, &default_text) >= 0) {
        defer w32.CoTaskMemFree(default_text);
        if (default_text) |d| dialog.default_len = @intCast(wide_string.toUtf8(&dialog.default_buf, std.mem.span(d)));
    }
    tab.dialog = dialog;
    var buf: [600]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "A {s} dialog opened: {s}", .{ @tagName(dialog.kind), dialog.message() }) catch "A dialog opened";
    tab.page_log.add(w32.GetTickCount64(), .info, line);
    panel.dialogChanged(tab);
}

fn onDownloadStarting(ref: TabRef, _: *webview2.WebView, args: *webview2.DownloadStartingArgs) void {
    _, const tab = find(ref) orelse return;
    var download: ?*webview2.Download = null;
    if (args.vtable.get_DownloadOperation(args, &download) < 0) return;
    const d = download orelse return;
    defer d.release();
    var buf: [1200]u8 = undefined;
    tab.page_log.add(w32.GetTickCount64(), .info, describeDownload(d, "Downloading", &buf));
    var token: webview2.Token = undefined;
    if (DownloadState.create(ref)) |h| {
        _ = d.vtable.add_StateChanged(d, h, &token);
        _ = h.release();
    }
}

fn onDownloadState(ref: TabRef, d: *webview2.Download, _: ?*anyopaque) void {
    _, const tab = find(ref) orelse return;
    var state: c_int = 0;
    if (d.vtable.get_State(d, &state) < 0) return;
    var buf: [1200]u8 = undefined;
    switch (state) {
        webview2.Download.completed => tab.page_log.add(w32.GetTickCount64(), .info, describeDownload(d, "Downloaded", &buf)),
        webview2.Download.interrupted => tab.page_log.add(w32.GetTickCount64(), .@"error", describeDownload(d, "Download failed:", &buf)),
        else => {},
    }
}

fn describeDownload(d: *webview2.Download, verb: []const u8, buf: []u8) []const u8 {
    var uri_buf: [500]u8 = undefined;
    var path_buf: [600]u8 = undefined;
    var uri: ?[*:0]u16 = null;
    var path: ?[*:0]u16 = null;
    _ = d.vtable.get_Uri(d, &uri);
    defer w32.CoTaskMemFree(uri);
    _ = d.vtable.get_ResultFilePath(d, &path);
    defer w32.CoTaskMemFree(path);
    var bytes: i64 = 0;
    _ = d.vtable.get_BytesReceived(d, &bytes);
    const uri_text = if (uri) |u| uri_buf[0..wide_string.toUtf8(&uri_buf, std.mem.span(u))] else "";
    const path_text = if (path) |p| path_buf[0..wide_string.toUtf8(&path_buf, std.mem.span(p))] else "";
    return std.fmt.bufPrint(buf, "{s} {s} to {s} ({d} bytes)", .{ verb, uri_text, path_text, bytes }) catch verb;
}

const Devtools = enum { console, exception, browser, request, response, failed, attached, detached, file_chooser };

fn eventName(comptime event: Devtools) [:0]const u16 {
    @setEvalBranchQuota(20_000);
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(switch (event) {
        .console => "Runtime.consoleAPICalled",
        .exception => "Runtime.exceptionThrown",
        .browser => "Log.entryAdded",
        .request => "Network.requestWillBeSent",
        .response => "Network.responseReceived",
        .failed => "Network.loadingFailed",
        .attached => "Target.attachedToTarget",
        .detached => "Target.detachedFromTarget",
        .file_chooser => "Page.fileChooserOpened",
    });
}

fn DevtoolsEvent(comptime event: Devtools) type {
    return webview2.Handler(webview2.iid_cdp_event, TabRef, *webview2.WebView, *webview2.EventArgs, struct {
        fn f(ref: TabRef, _: *webview2.WebView, args: *webview2.EventArgs) void {
            _, const tab = find(ref) orelse return;
            var json: ?[*:0]u16 = null;
            if (args.vtable.get_ParameterObjectAsJson(args, &json) < 0) return;
            defer w32.CoTaskMemFree(json);
            const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json orelse return)) catch return;
            defer alloc.free(utf8);
            var session_buf: [64]u8 = undefined;
            const session = args.sessionId(&session_buf);
            switch (event) {
                .console => tab.page_log.addEvent(alloc, w32.GetTickCount64(), .console, utf8),
                .exception => tab.page_log.addEvent(alloc, w32.GetTickCount64(), .exception, utf8),
                .browser => tab.page_log.addEvent(alloc, w32.GetTickCount64(), .browser, utf8),
                else => {
                    const parsed = std.json.parseFromSlice(std.json.Value, alloc, utf8, .{}) catch return;
                    defer parsed.deinit();
                    onDevtools(tab, event, parsed.value, session);
                },
            }
        }
    }.f);
}

fn onDevtools(tab: *BrowserTab, event: Devtools, params: std.json.Value, session: []const u8) void {
    const now = w32.GetTickCount64();
    var buf: [700]u8 = undefined;
    switch (event) {
        .request => {
            const request = field(params, "request") orelse return;
            tab.requests.remember(string(params, "requestId") orelse return, string(request, "url") orelse return);
        },
        .response => {
            const response = field(params, "response") orelse return;
            const status = json_read.number(response, "status") orelse return;
            if (status < 400) return;
            const line = std.fmt.bufPrint(&buf, "{d} {s}: {s}", .{
                @as(u32, @intFromFloat(status)),
                string(response, "statusText") orelse "",
                string(response, "url") orelse "",
            }) catch return;
            tab.page_log.add(now, .@"error", line);
        },
        .failed => {
            if (json_read.boolean(params, "canceled") orelse false) return;
            const url = tab.requests.urlOf(string(params, "requestId") orelse return) orelse "a request";
            const line = std.fmt.bufPrint(&buf, "Failed to load {s}: {s}", .{ url, string(params, "errorText") orelse "" }) catch return;
            tab.page_log.add(now, .@"error", line);
        },
        .attached => {
            const child = string(params, "sessionId") orelse return;
            const info = field(params, "targetInfo") orelse return;
            const kind = string(info, "type") orelse return;
            if (!std.mem.eql(u8, kind, "iframe")) return;
            if (!tab.frames.add(child, string(info, "targetId") orelse return, session)) return;
            enableDomains(tab, child);
        },
        .detached => tab.frames.remove(string(params, "sessionId") orelse return),
        .file_chooser => {
            const node = json_read.number(params, "backendNodeId") orelse return;
            const line = std.fmt.bufPrint(&buf, "A file chooser opened for [ref={d}]. Pick files with browser_action upload on that ref.", .{@as(i64, @intFromFloat(node))}) catch return;
            tab.page_log.add(now, .info, line);
        },
        .console, .exception, .browser => {},
    }
}
