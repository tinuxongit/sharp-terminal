const std = @import("std");
const w32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const json_read = @import("json_read.zig");
const BrowserPanel = @import("BrowserPanel.zig");
const browser_engine = @import("browser_engine.zig");

const field = json_read.field;
const string = json_read.string;
const alloc = std.heap.smp_allocator;

pub const timer_id: usize = 0x5349;
const delay_ms = 5_000;
const kept_days = 400;

const CookiesRead = webview2.Handler(webview2.iid_cdp_completed, browser_engine.TabRef, w32.HRESULT, ?[*:0]const u16, onCookies);

pub fn schedule(panel: *BrowserPanel) void {
    _ = w32.SetTimer(panel.hwnd, timer_id, delay_ms, null);
}

pub fn keep(panel: *BrowserPanel) void {
    _ = w32.KillTimer(panel.hwnd, timer_id);
    for (panel.tabs()) |tab| {
        if (!tab.ready) continue;
        const handler = CookiesRead.create(browser_engine.refOf(panel, tab)) orelse return;
        defer _ = handler.release();
        if (tab.devtools("Network.getAllCookies", "{}", handler)) return;
    }
}

fn onCookies(ref: browser_engine.TabRef, result: w32.HRESULT, json: ?[*:0]const u16) void {
    if (result < 0) return;
    _, const tab = browser_engine.find(ref) orelse return;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json orelse return)) catch return;
    defer alloc.free(utf8);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, utf8, .{}) catch return;
    const cookies = field(parsed, "cookies") orelse return;
    if (cookies != .array) return;
    const expires: f64 = @floatFromInt(unixNow() + kept_days * std.time.s_per_day);
    var kept = std.json.Array.init(a);
    for (cookies.array.items) |cookie| {
        if (!(json_read.boolean(cookie, "session") orelse false)) continue;
        kept.append(lasting(a, cookie, expires) catch continue) catch return;
    }
    if (kept.items.len == 0) return;
    const params = std.json.Stringify.valueAlloc(a, .{ .cookies = std.json.Value{ .array = kept } }, .{}) catch return;
    browser_engine.send(tab, "Network.setCookies", params);
}

fn unixNow() i64 {
    var now: w32.FILETIME = undefined;
    w32.GetSystemTimeAsFileTime(&now);
    const ticks = (@as(u64, now.dwHighDateTime) << 32) | now.dwLowDateTime;
    return @intCast((ticks -| 116_444_736_000_000_000) / 10_000_000);
}

fn lasting(a: std.mem.Allocator, cookie: std.json.Value, expires: f64) !std.json.Value {
    var out: std.json.ObjectMap = .empty;
    const domain = string(cookie, "domain") orelse return error.Skipped;
    const path = string(cookie, "path") orelse "/";
    const secure = json_read.boolean(cookie, "secure") orelse false;
    try out.put(a, "name", .{ .string = string(cookie, "name") orelse return error.Skipped });
    try out.put(a, "value", .{ .string = string(cookie, "value") orelse "" });
    try out.put(a, "path", .{ .string = path });
    if (std.mem.startsWith(u8, domain, ".")) {
        try out.put(a, "domain", .{ .string = domain });
    } else {
        try out.put(a, "url", .{ .string = try std.fmt.allocPrint(a, "{s}://{s}{s}", .{ if (secure) "https" else "http", domain, path }) });
    }
    try out.put(a, "secure", .{ .bool = secure });
    try out.put(a, "httpOnly", .{ .bool = json_read.boolean(cookie, "httpOnly") orelse false });
    if (string(cookie, "sameSite")) |same| try out.put(a, "sameSite", .{ .string = same });
    if (field(cookie, "partitionKey")) |key| try out.put(a, "partitionKey", key);
    try out.put(a, "expires", .{ .float = expires });
    return .{ .object = out };
}
