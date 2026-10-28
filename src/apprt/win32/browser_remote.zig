//! Calls into the browser panel from other threads. Claude's tools run on
//! the MCP server's threads, but WebView2 answers only on the UI thread, so
//! each call is posted to the app's message window and the caller waits
//! for the UI thread's answer.
const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_settings = @import("browser_settings.zig");
const BrowserTab = @import("BrowserTab.zig");
const browser_dock = @import("browser_dock.zig");
const webview2 = @import("webview2.zig");

const alloc = std.heap.smp_allocator;

pub const History = enum { back, forward, reload };

pub const Op = union(enum) {
    /// Show the panel, creating it if needed; with a url, open it in a new
    /// tab. Answers the tab's id.
    open: struct { url: []const u8 },
    /// Show the panel and tab `tab`, or the active one for 0. Answers its id.
    select: struct { tab: u32 },
    /// Whether the tab's page can take calls yet.
    ready: struct { tab: u32 },
    /// A DevTools Protocol method and its JSON parameters.
    devtools: struct { tab: u32, method: []const u8, params: []const u8 },
    history: struct { tab: u32, step: History },
    /// The tab's log from `since_ms` (GetTickCount64) on.
    logs: struct { tab: u32, since_ms: u64, clear: bool },
    /// Every tab as JSON: id, title, url and whether it is active.
    tabs,
    close: struct { tab: u32 },
};

/// One call, shared by the waiting thread and the UI thread; the last of
/// the two to let go frees it, so a caller that gave up never leaves the
/// UI thread holding freed memory.
pub const Request = struct {
    op: Op,
    refs: std.atomic.Value(u32) = .init(2),
    done: w32.HANDLE,
    ok: bool = false,
    /// DevTools' JSON answer, or text; owned.
    result: []u8 = &.{},

    fn create(op: Op) ?*Request {
        const self = alloc.create(Request) catch return null;
        const event = w32.CreateEventW(null, 1, 0, null) orelse {
            alloc.destroy(self);
            return null;
        };
        // The strings are copied, since the caller may stop waiting.
        const owned: Op = switch (op) {
            .devtools => |d| blk: {
                const method = alloc.dupe(u8, d.method) catch return self.fail(event);
                const params = alloc.dupe(u8, d.params) catch {
                    alloc.free(method);
                    return self.fail(event);
                };
                break :blk .{ .devtools = .{ .tab = d.tab, .method = method, .params = params } };
            },
            .open => |o| .{ .open = .{ .url = alloc.dupe(u8, o.url) catch return self.fail(event) } },
            else => op,
        };
        self.* = .{ .op = owned, .done = event };
        return self;
    }

    fn fail(self: *Request, event: w32.HANDLE) ?*Request {
        _ = w32.CloseHandle(event);
        alloc.destroy(self);
        return null;
    }

    fn release(self: *Request) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        switch (self.op) {
            .devtools => |d| {
                alloc.free(d.method);
                alloc.free(d.params);
            },
            .open => |o| alloc.free(o.url),
            else => {},
        }
        alloc.free(self.result);
        _ = w32.CloseHandle(self.done);
        alloc.destroy(self);
    }

    /// The UI thread's answer, which also lets go of its reference.
    pub fn finish(self: *Request, ok: bool, result: []const u8) void {
        self.ok = ok;
        self.result = alloc.dupe(u8, result) catch &.{};
        _ = w32.SetEvent(self.done);
        self.release();
    }

    fn finishId(self: *Request, id: u32) void {
        var buf: [16]u8 = undefined;
        self.finish(true, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "");
    }
};

/// Posted to the app's message window with a *Request.
pub const message: u32 = w32.WM_APP + 6;

/// The app's message window, set once at startup.
pub var target: ?w32.HWND = null;

pub const Answer = struct {
    ok: bool,
    /// Owned by the caller, freed with free().
    text: []u8,

    pub fn free(self: Answer) void {
        alloc.free(self.text);
    }
};

/// Run `op` on the UI thread and wait up to `timeout_ms` for its answer.
pub fn call(op: Op, timeout_ms: u32) error{ Unavailable, TimedOut }!Answer {
    const hwnd = target orelse return error.Unavailable;
    const request = Request.create(op) orelse return error.Unavailable;
    defer request.release();
    if (w32.PostMessageW(hwnd, message, @intFromPtr(request), 0) == 0) {
        // The UI thread never gets its reference, so drop it here.
        request.release();
        return error.Unavailable;
    }
    if (w32.WaitForSingleObject(request.done, timeout_ms) != w32.WAIT_OBJECT_0) return error.TimedOut;
    return .{ .ok = request.ok, .text = alloc.dupe(u8, request.result) catch return error.Unavailable };
}

const DevtoolsDone = webview2.Handler(webview2.iid_cdp_completed, usize, w32.HRESULT, ?[*:0]const u16, onDevtools);

fn onDevtools(context: usize, result: w32.HRESULT, json: ?[*:0]const u16) void {
    const request: *Request = @ptrFromInt(context);
    const wide = std.mem.span(json orelse std.unicode.utf8ToUtf16LeStringLiteral(""));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch return request.finish(false, "Out of memory");
    defer alloc.free(utf8);
    request.finish(result >= 0, utf8);
}

/// The window whose panel Claude uses: the first with the panel showing,
/// else the first with a panel, else (for open) the first that may have one.
fn windowFor(app: *App, opening: bool) ?*Window {
    for (app.windows.items) |w| if (w.browser != null and w.browser_shown) return w;
    for (app.windows.items) |w| if (w.browser != null) return w;
    if (opening) for (app.windows.items) |w| if (browser_dock.enabled(w)) return w;
    return null;
}

const not_open = "The browser isn't open. Call browser_open first.";

/// Answer a posted request on the UI thread.
pub fn serve(app: *App, request: *Request) void {
    if (!app.config.@"ai-tools-browser") return request.finish(false, "The browser is off in Sharp's Settings > AI > Tools.");
    const window = windowFor(app, request.op == .open or request.op == .select) orelse return request.finish(false, not_open);
    switch (request.op) {
        .open => |o| {
            const existed = window.browser != null;
            const url: ?[]const u8 = if (o.url.len > 0) o.url else null;
            if (!browser_dock.open(window, if (existed) null else url)) return request.finish(false, "Sharp couldn't open its browser.");
            const panel = window.browser orelse return request.finish(false, not_open);
            if (existed and url != null) {
                const id = panel.openTab(url.?) orelse return request.finish(false, "Every tab is in use. Close one with browser_close.");
                return request.finishId(id);
            }
            const tab = panel.activeTab() orelse return request.finish(false, not_open);
            request.finishId(tab.id);
        },
        .select => |s| {
            if (!window.browser_shown and !browser_dock.open(window, null)) return request.finish(false, not_open);
            const panel = window.browser orelse return request.finish(false, not_open);
            const tab = (if (s.tab == 0) panel.activeTab() else panel.tabById(s.tab)) orelse
                return request.finish(false, "There is no such tab. browser_tabs lists them.");
            for (panel.tabs(), 0..) |t, i| if (t == tab and i != panel.active) panel.select(i);
            request.finishId(tab.id);
        },
        .tabs => {
            const panel = window.browser orelse return request.finish(true, "[]");
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer };
            json.beginArray() catch {};
            for (panel.tabs(), 0..) |tab, i| {
                var buf: [2048]u8 = undefined;
                json.write(.{ .id = tab.id, .title = tab.title(), .url = tab.source(&buf) orelse "", .active = i == panel.active }) catch {};
            }
            json.endArray() catch {};
            request.finish(true, out.written());
        },
        inline .ready, .devtools, .history, .logs, .close => |op, tag| {
            const panel = window.browser orelse return request.finish(false, not_open);
            const tab = panel.tabById(op.tab) orelse return request.finish(false, "That tab was closed. browser_tabs lists the open ones.");
            serveTab(panel, tab, request, @unionInit(Op, @tagName(tag), op));
        },
    }
}

fn serveTab(panel: *BrowserPanel, tab: *BrowserTab, request: *Request, op: Op) void {
    switch (op) {
        .ready => request.finish(tab.ready, if (panel.failed) browser_settings.data.unavailable else ""),
        .history => |h| {
            const webview = tab.webview orelse return request.finish(false, "The page is still loading.");
            _ = switch (h.step) {
                .back => webview.vtable.GoBack(webview),
                .forward => webview.vtable.GoForward(webview),
                .reload => webview.vtable.Reload(webview),
            };
            request.finish(true, "");
        },
        .logs => |l| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            tab.page_log.write(&out.writer, l.since_ms) catch {};
            if (l.clear) tab.page_log.clear();
            request.finish(true, out.written());
        },
        .close => {
            panel.closeTab(tab);
            request.finish(true, "");
        },
        .devtools => |d| {
            const handler = DevtoolsDone.create(@intFromPtr(request)) orelse return request.finish(false, "Out of memory");
            defer _ = handler.release();
            // From here the handler owns the UI thread's reference.
            if (!tab.devtools(d.method, d.params, handler)) request.finish(false, "The page is still loading.");
        },
        else => unreachable,
    }
}
