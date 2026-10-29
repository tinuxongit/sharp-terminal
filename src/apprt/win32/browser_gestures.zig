const std = @import("std");
const Value = std.json.Value;
const w32 = @import("win32.zig");
const browser_page = @import("browser_page.zig");
const pointer = @import("browser_pointer.zig");
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const Point = browser_page.Point;
const number = json_read.number;

const default_ms = 300;
const max_ms = 5000;
const step_ms = 16;

const Path = struct {
    from: Point,
    to: Point,
    steps: u32,
    pause_ms: u32,

    fn at(self: Path, step: u32) Point {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(self.steps));
        return .{ .x = self.from.x + (self.to.x - self.from.x) * t, .y = self.from.y + (self.to.y - self.from.y) * t };
    }
};

pub fn swipe(page: *Page, args: Value) !?[]const u8 {
    const need = "swipe needs x, y, toX and toY coordinates.";
    const from: Point = .{ .x = number(args, "x") orelse return page.fail(need, .{}), .y = number(args, "y") orelse return page.fail(need, .{}) };
    const to: Point = .{ .x = number(args, "toX") orelse return page.fail(need, .{}), .y = number(args, "toY") orelse return page.fail(need, .{}) };
    const duration = number(args, "duration") orelse default_ms;
    if (duration < 0 or duration > max_ms) return page.fail("Use a swipe duration from 0 to {d} milliseconds.", .{max_ms});
    const steps: u32 = @max(2, @as(u32, @intFromFloat(@round(duration / step_ms))));
    const path: Path = .{ .from = from, .to = to, .steps = steps, .pause_ms = @intFromFloat(duration / @as(f64, @floatFromInt(steps))) };
    try pointer.moveTo(page, from);
    const tab = try page.own();
    if (tab.mobile) {
        try touch(page, path);
        return null;
    }
    return drag(page, path);
}

fn touch(page: *Page, path: Path) !void {
    _ = try page.devtools("Input.dispatchTouchEvent", .{ .type = "touchStart", .touchPoints = .{path.at(0)} });
    for (1..path.steps + 1) |step| {
        w32.Sleep(path.pause_ms);
        _ = try page.devtools("Input.dispatchTouchEvent", .{ .type = "touchMove", .touchPoints = .{path.at(@intCast(step))} });
    }
    _ = try page.devtools("Input.dispatchTouchEvent", .{ .type = "touchEnd", .touchPoints = [0]Point{} });
}

fn drag(page: *Page, path: Path) !?[]const u8 {
    _ = try page.devtools("Input.setInterceptDrags", .{ .enabled = true });
    defer _ = page.devtools("Input.setInterceptDrags", .{ .enabled = false }) catch null;
    const start = path.at(0);
    _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mouseMoved", .x = start.x, .y = start.y, .button = "none", .buttons = 0 });
    _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mousePressed", .x = start.x, .y = start.y, .button = "left", .buttons = 1, .clickCount = 1 });
    for (1..path.steps + 1) |step| {
        w32.Sleep(path.pause_ms);
        const p = path.at(@intCast(step));
        _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mouseMoved", .x = p.x, .y = p.y, .button = "left", .buttons = 1 });
    }
    const dragged = try page.remoteCall(.{ .drag = .{ .tab = page.tab } }, 5_000);
    if (dragged.len > 0) {
        const data = std.json.parseFromSliceLeaky(Value, page.arena, dragged, .{ .allocate = .alloc_always }) catch Value.null;
        for ([_][]const u8{ "dragEnter", "dragOver", "drop" }) |kind| {
            _ = try page.devtools("Input.dispatchDragEvent", .{ .type = kind, .x = path.to.x, .y = path.to.y, .data = data });
        }
    }
    _ = try page.devtools("Input.dispatchMouseEvent", .{ .type = "mouseReleased", .x = path.to.x, .y = path.to.y, .button = "left", .buttons = 0, .clickCount = 1 });
    if (dragged.len == 0) return null;
    return "Dragged content and dropped it at the end point";
}
