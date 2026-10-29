const std = @import("std");
const browser_page = @import("browser_page.zig");
const locator = @import("browser_locator.zig");
const pointer = @import("browser_pointer.zig");
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const field = json_read.field;
const number = json_read.number;
const string = json_read.string;

const max_full_height = 16_000;

const Clip = struct { x: f64, y: f64, width: f64, height: f64, scale: f64 };

pub fn take(page: *Page, scope: ?locator.Node, full: bool) ![]const u8 {
    const info = try page.info();
    const ratio = 1 / @max(info.pixel_ratio, 0.1);
    const clip: Clip = if (scope) |node| element: {
        const b = try locator.elementBox(page, node, .border);
        const scrolled = try page.info();
        break :element .{ .x = b.left + scrolled.scroll_x, .y = b.top + scrolled.scroll_y, .width = @max(1, b.right - b.left), .height = @max(1, b.bottom - b.top), .scale = ratio };
    } else if (full) whole: {
        const metrics = try page.devtools("Page.getLayoutMetrics", browser_page.no_params);
        const size = field(metrics, "cssContentSize") orelse return page.fail("The page gave no size.", .{});
        break :whole .{ .x = 0, .y = 0, .width = number(size, "width") orelse info.width, .height = @min(number(size, "height") orelse info.height, max_full_height), .scale = ratio };
    } else .{ .x = info.scroll_x, .y = info.scroll_y, .width = info.width, .height = info.height, .scale = ratio };
    const beyond = scope != null or full;
    pointer.hide(page);
    defer pointer.rest(page);
    if (beyond) _ = try page.remoteCall(.{ .cover = .{ .tab = page.tab, .on = true } }, 5_000);
    defer if (beyond) {
        _ = page.remoteCall(.{ .cover = .{ .tab = page.tab, .on = false } }, 5_000) catch null;
    };
    const answer = try page.devtools("Page.captureScreenshot", .{
        .format = "jpeg",
        .quality = 80,
        .fromSurface = true,
        .captureBeyondViewport = beyond,
        .clip = clip,
    });
    return string(answer, "data") orelse page.fail("The page gave no picture.", .{});
}
