//! Calls into the browser panel from other threads. Claude's tools run on
//! the MCP server's threads, but WebView2 answers only on the UI thread, so
//! each call is posted to the app's message window and the caller waits
//! for the UI thread's answer.
const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_dock = @import("browser_dock.zig");
const webview2 = @import("webview2.zig");

const alloc = std.heap.smp_allocator;

pub const Op = union(enum) {
    /// A DevTools Protocol method and its JSON parameters.
    devtools: struct { method: []const u8, params: []const u8 },
    /// Show a window's panel, creating it if needed.
    open,
    /// Whether the panel's page can take calls yet.
    ready,
    back,
    forward,
    reload,
    /// The page's log from `since_ms` (GetTickCount64) on.
    logs: struct { since_ms: u64, clear: bool },
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
        var owned = op;
        switch (op) {
            .devtools => |d| {
                const method = alloc.dupe(u8, d.method) catch return self.fail(event);
                const params = alloc.dupe(u8, d.params) catch {
                    alloc.free(method);
                    return self.fail(event);
                };
                owned = .{ .devtools = .{ .method = method, .params = params } };
            },
            else => {},
        }
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

const DevtoolsDone = webview2.Handler(webview2.iid_cdp_completed, w32.HRESULT, ?[*:0]const u16, onDevtools);

fn onDevtools(context: usize, result: w32.HRESULT, json: ?[*:0]const u16) void {
    const request: *Request = @ptrFromInt(context);
    const wide = std.mem.span(json orelse std.unicode.utf8ToUtf16LeStringLiteral(""));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch return request.finish(false, "Out of memory");
    defer alloc.free(utf8);
    request.finish(result >= 0, utf8);
}

/// The window whose panel Claude uses: the first with the panel showing,
/// else the first with a panel, else (for open) the first window.
fn windowFor(app: *App, opening: bool) ?*Window {
    for (app.windows.items) |w| if (w.browser != null and w.browser_shown) return w;
    for (app.windows.items) |w| if (w.browser != null) return w;
    if (opening) for (app.windows.items) |w| if (browser_dock.enabled(w)) return w;
    return null;
}

/// Answer a posted request on the UI thread.
pub fn serve(app: *App, request: *Request) void {
    if (!app.config.@"ai-tools-browser") return request.finish(false, "The browser is off in Sharp's Settings > AI > Tools.");
    const window = windowFor(app, request.op == .open) orelse
        return request.finish(false, "The browser isn't open. Call browser_open first.");
    if (request.op == .open) {
        if (!window.browser_shown) browser_dock.toggle(window);
        return request.finish(window.browser != null, "");
    }
    const panel = window.browser orelse return request.finish(false, "The browser isn't open. Call browser_open first.");
    switch (request.op) {
        .open => unreachable,
        .ready => request.finish(panel.webview != null, if (panel.failed) BrowserPanel.data.unavailable else ""),
        .back, .forward, .reload => {
            const webview = panel.webview orelse return request.finish(false, "The page is still loading.");
            _ = switch (request.op) {
                .back => webview.vtable.GoBack(webview),
                .forward => webview.vtable.GoForward(webview),
                else => webview.vtable.Reload(webview),
            };
            request.finish(true, "");
        },
        .logs => |l| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            panel.page_log.write(&out.writer, l.since_ms) catch {};
            if (l.clear) panel.page_log.clear();
            request.finish(true, out.written());
        },
        .devtools => |d| {
            const handler = DevtoolsDone.create(@intFromPtr(request)) orelse return request.finish(false, "Out of memory");
            defer _ = handler.release();
            // From here the handler owns the UI thread's reference.
            if (!panel.devtools(d.method, d.params, handler)) request.finish(false, "The page is still loading.");
        },
    }
}
