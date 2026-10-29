const std = @import("std");
const w32 = @import("win32.zig");
const browser_page = @import("browser_page.zig");
const locator = @import("browser_locator.zig");
const Page = browser_page.Page;
const Point = browser_page.Point;

const Color = struct { r: u8, g: u8, b: u8, a: f64 };
const fill: Color = .{ .r = 250, .g = 250, .b = 250, .a = 0.96 };
const outline: Color = .{ .r = 20, .g = 20, .b = 20, .a = 0.9 };
const pressed_fill: Color = .{ .r = 244, .g = 211, .b = 78, .a = 0.96 };
const flash_fill: Color = .{ .r = 244, .g = 211, .b = 78, .a = 0.16 };
const flash_outline: Color = .{ .r = 244, .g = 211, .b = 78, .a = 0.9 };
const frame_ms = 16;

pub fn moveTo(page: *Page, to: Point) !void {
    const tab = try page.own();
    defer _ = page.remoteCall(.{ .pointer = .{ .tab = page.tab, .x = to.x, .y = to.y } }, 5_000) catch null;
    if (!tab.in_sight) return;
    const from: Point = if (tab.pointer) |p| .{ .x = p[0], .y = p[1] } else .{ .x = to.x - 60, .y = to.y - 40 };
    const frames: u32 = 16;
    for (1..frames + 1) |frame| {
        const t = easeOut(@as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(frames)));
        try draw(page, tab, .{ .x = from.x + (to.x - from.x) * t, .y = from.y + (to.y - from.y) * t }, false);
        w32.Sleep(frame_ms);
    }
}

pub fn press(page: *Page, at: Point, box: ?locator.Box) !void {
    const tab = try page.own();
    if (!tab.in_sight) return;
    if (box) |b| {
        _ = try page.devtools("Overlay.highlightRect", .{
            .x = @as(i64, @intFromFloat(@round(b.left))),
            .y = @as(i64, @intFromFloat(@round(b.top))),
            .width = @as(i64, @intFromFloat(@max(1, @round(b.right - b.left)))),
            .height = @as(i64, @intFromFloat(@max(1, @round(b.bottom - b.top)))),
            .color = flash_fill,
            .outlineColor = flash_outline,
        });
        w32.Sleep(140);
    }
    try draw(page, tab, at, true);
    w32.Sleep(90);
}

pub fn rest(page: *Page) void {
    const tab = page.own() catch return;
    const p = tab.pointer orelse return;
    if (tab.in_sight) draw(page, tab, .{ .x = p[0], .y = p[1] }, false) catch {
        page.failure = null;
    };
}

pub fn hide(page: *Page) void {
    _ = page.devtools("Overlay.hideHighlight", browser_page.no_params) catch {
        page.failure = null;
    };
}

fn draw(page: *Page, tab: browser_page.TabInfo, at: Point, down: bool) !void {
    const size = 1 / std.math.clamp(tab.scale, 0.12, 1);
    const quad = if (tab.mobile) dot(at, size) else arrow(at, size);
    _ = try page.devtools("Overlay.highlightQuad", .{ .quad = quad, .color = if (down) pressed_fill else fill, .outlineColor = outline });
}

fn arrow(p: Point, size: f64) [8]f64 {
    return .{ p.x, p.y, p.x, p.y + 19 * size, p.x + 5.5 * size, p.y + 14.5 * size, p.x + 13 * size, p.y + 14 * size };
}

fn dot(p: Point, size: f64) [8]f64 {
    const r = 11 * size;
    return .{ p.x, p.y - r, p.x + r, p.y, p.x, p.y + r, p.x - r, p.y };
}

fn easeOut(t: f64) f64 {
    return 1 - std.math.pow(f64, 1 - t, 3);
}
