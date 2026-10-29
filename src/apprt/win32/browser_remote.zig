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
const browser_chats = @import("browser_chats.zig");

const Chat = browser_chats.Chat;

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
    /// A DevTools Protocol method and its JSON parameters, in the page's
    /// own session or a frame's.
    devtools: struct { tab: u32, session: []const u8 = "", method: []const u8, params: []const u8 },
    history: struct { tab: u32, step: History },
    /// The tab's log from `since_ms` (GetTickCount64) on.
    logs: struct { tab: u32, since_ms: u64, clear: bool },
    /// Every tab as JSON: id, title, url and whether it is active.
    tabs,
    close: struct { tab: u32 },
    idle,
    dialog: struct { tab: u32 },
    answer: struct { tab: u32, accept: bool, text: []const u8 },
    frames: struct { tab: u32 },
    viewport: struct { tab: u32, width: u32, height: u32, mobile: ?bool },
    cover: struct { tab: u32, on: bool },
    pointer: struct { tab: u32, x: f64, y: f64 },
    drag: struct { tab: u32 },
    media: struct { tab: u32, color: ?BrowserTab.ColorScheme, motion: ?BrowserTab.Motion },
};

/// One call, shared by the waiting thread and the UI thread; the last of
/// the two to let go frees it, so a caller that gave up never leaves the
/// UI thread holding freed memory.
pub const Request = struct {
    chat: Chat,
    op: Op,
    refs: std.atomic.Value(u32) = .init(2),
    done: w32.HANDLE,
    ok: bool = false,
    /// DevTools' JSON answer, or text; owned.
    result: []u8 = &.{},

    fn create(chat: *const Chat, op: Op) ?*Request {
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
                const session = alloc.dupe(u8, d.session) catch {
                    alloc.free(method);
                    alloc.free(params);
                    return self.fail(event);
                };
                break :blk .{ .devtools = .{ .tab = d.tab, .session = session, .method = method, .params = params } };
            },
            .open => |o| .{ .open = .{ .url = alloc.dupe(u8, o.url) catch return self.fail(event) } },
            .answer => |a| .{ .answer = .{ .tab = a.tab, .accept = a.accept, .text = alloc.dupe(u8, a.text) catch return self.fail(event) } },
            else => op,
        };
        self.* = .{ .chat = chat.*, .op = owned, .done = event };
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
                alloc.free(d.session);
            },
            .open => |o| alloc.free(o.url),
            .answer => |a| alloc.free(a.text),
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
pub fn call(chat: *const Chat, op: Op, timeout_ms: u32) error{ Unavailable, TimedOut }!Answer {
    return callWatching(chat, op, timeout_ms, null) catch |err| switch (err) {
        error.Dialog => error.TimedOut,
        else => |e| e,
    };
}

pub fn callWatching(chat: *const Chat, op: Op, timeout_ms: u32, watched: ?u32) error{ Unavailable, TimedOut, Dialog }!Answer {
    const hwnd = target orelse return error.Unavailable;
    const request = Request.create(chat, op) orelse return error.Unavailable;
    defer request.release();
    if (w32.PostMessageW(hwnd, message, @intFromPtr(request), 0) == 0) {
        // The UI thread never gets its reference, so drop it here.
        request.release();
        return error.Unavailable;
    }
    var waited: u32 = 0;
    while (true) {
        const slice: u32 = if (watched == null) timeout_ms else @min(250, timeout_ms - waited);
        if (w32.WaitForSingleObject(request.done, slice) == w32.WAIT_OBJECT_0) break;
        waited += slice;
        if (waited >= timeout_ms) return error.TimedOut;
        if (dialogShown(chat, watched.?)) return error.Dialog;
    }
    return .{ .ok = request.ok, .text = alloc.dupe(u8, request.result) catch return error.Unavailable };
}

fn dialogShown(chat: *const Chat, tab: u32) bool {
    const answer = call(chat, .{ .dialog = .{ .tab = tab } }, 2_000) catch return false;
    defer answer.free();
    return answer.ok and answer.text.len > 0;
}

const Ignore = @import("browser_engine.zig").Ignore;
const DevtoolsDone = webview2.Handler(webview2.iid_cdp_completed, usize, w32.HRESULT, ?[*:0]const u16, onDevtools);

fn onDevtools(context: usize, result: w32.HRESULT, json: ?[*:0]const u16) void {
    const request: *Request = @ptrFromInt(context);
    const wide = std.mem.span(json orelse std.unicode.utf8ToUtf16LeStringLiteral(""));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch return request.finish(false, "Out of memory");
    defer alloc.free(utf8);
    request.finish(result >= 0, utf8);
}

const not_open = "This chat has no browser tab. Call browser_open first.";

/// Answer a posted request on the UI thread. Each chat sees and drives
/// only its own tabs.
pub fn serve(app: *App, request: *Request) void {
    if (!app.config.@"ai-tools-browser") return request.finish(false, "The browser is off in Sharp's Settings > AI > Tools.");
    const placed = browser_chats.place(app, &request.chat) orelse return request.finish(false, "Sharp has no window that can show the browser.");
    const window = placed.window;
    const owner = placed.owner;
    switch (request.op) {
        .open => |o| {
            const panel = browser_dock.panelOf(window) orelse return request.finish(false, "Sharp couldn't open its browser.");
            const existing = panel.activeOf(owner);
            const tab = if (o.url.len == 0 and existing != null) existing.? else blk: {
                const id = panel.openTab(owner, if (o.url.len > 0) o.url else panel.engine.home) orelse
                    return request.finish(false, "Every tab is in use. Close one with browser_close.");
                break :blk panel.tabById(id) orelse return request.finish(false, not_open);
            };
            bringIn(window, panel, placed, tab);
            request.finishId(tab.id);
        },
        .select => |s| {
            const panel = window.browser orelse return request.finish(false, not_open);
            const tab = (if (s.tab == 0) panel.activeOf(owner) else panel.ownTab(owner, s.tab)) orelse
                return request.finish(false, if (s.tab == 0) not_open else "There is no such tab. browser_tabs lists them.");
            panel.select(tab);
            bringIn(window, panel, placed, tab);
            request.finishId(tab.id);
        },
        .tabs => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer };
            json.beginArray() catch {};
            if (window.browser) |panel| {
                const active = panel.activeOf(owner);
                var own: BrowserPanel.OwnTabs = undefined;
                for (panel.ownTabs(owner, &own)) |tab| {
                    var buf: [2048]u8 = undefined;
                    json.write(.{
                        .id = tab.id,
                        .title = tab.title(),
                        .url = tab.source(&buf) orelse "",
                        .active = tab == active,
                        .width = tab.viewport[0],
                        .height = tab.viewport[1],
                        .mobile = tab.mobile,
                        .in_sight = panel.inSight(tab),
                        .scale = panel.shownScale(tab),
                        .pointer = tab.pointer,
                    }) catch {};
                }
            }
            json.endArray() catch {};
            request.finish(true, out.written());
        },
        .idle => {
            if (window.browser) |panel| {
                var own: BrowserPanel.OwnTabs = undefined;
                for (panel.ownTabs(owner, &own)) |tab| panel.park(tab, false);
            }
            request.finish(true, "");
        },
        inline .ready, .devtools, .history, .logs, .close, .dialog, .answer, .frames, .viewport, .cover, .pointer, .drag, .media => |op, tag| {
            const panel = window.browser orelse return request.finish(false, not_open);
            const tab = panel.ownTab(owner, op.tab) orelse return request.finish(false, "That tab was closed. browser_tabs lists the open ones.");
            serveTab(panel, tab, request, @unionInit(Op, @tagName(tag), op));
        },
    }
}

fn bringIn(window: *Window, panel: *BrowserPanel, placed: browser_chats.Placement, tab: *BrowserTab) void {
    if (!placed.in_sight) return panel.park(tab, true);
    panel.showOwner(placed.owner);
    if (!window.browser_shown) _ = browser_dock.open(window);
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
            if (!tab.devtoolsIn(d.session, d.method, d.params, handler)) request.finish(false, "The page is still loading.");
        },
        .dialog => {
            const dialog = tab.dialog orelse return request.finish(true, "");
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            std.json.Stringify.value(.{ .kind = @tagName(dialog.kind), .message = dialog.message() }, .{}, &out.writer) catch {};
            request.finish(true, out.written());
        },
        .answer => |a| {
            if (tab.dialog == null) return request.finish(false, "No dialog is open on this page.");
            panel.answerDialog(tab, a.accept, a.text);
            request.finish(true, "");
        },
        .viewport => |v| {
            panel.setViewport(tab, v.width, v.height, v.mobile);
            request.finish(true, "");
        },
        .cover => |c| {
            panel.coverPage(tab, c.on);
            request.finish(true, "");
        },
        .pointer => |p| {
            tab.pointer = .{ p.x, p.y };
            request.finish(true, "");
        },
        .media => |m| {
            if (m.color) |c| tab.color_scheme = c;
            if (m.motion) |motion| tab.motion = motion;
            const handler = Ignore.create(0) orelse return request.finish(false, "Out of memory");
            defer _ = handler.release();
            tab.emulateMedia(handler);
            request.finish(true, "");
        },
        .drag => {
            const dragged = tab.drag_data orelse return request.finish(true, "");
            request.finish(true, dragged);
            tab.setDragData(null);
        },
        .frames => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer };
            json.beginArray() catch {};
            for (tab.frames.all()) |f| {
                json.write(.{ .key = f.key, .session = f.session.get(), .target = f.target.get(), .parent = f.parent.get() }) catch {};
            }
            json.endArray() catch {};
            request.finish(true, out.written());
        },
        else => unreachable,
    }
}
