const std = @import("std");
const Value = std.json.Value;
const browser_page = @import("browser_page.zig");
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const Point = browser_page.Point;
const field = json_read.field;
const string = json_read.string;
const number = json_read.number;
const asNumber = json_read.asNumber;

pub const Node = struct {
    backend: ?i64 = null,
    object: ?[]const u8 = null,
    session: []const u8 = "",
    frame: ?browser_page.Frame = null,

    pub fn params(self: Node) NodeParams {
        return .{ .backendNodeId = self.backend, .objectId = self.object };
    }
};

const NodeParams = struct { backendNodeId: ?i64 = null, objectId: ?[]const u8 = null };

pub const Box = struct { left: f64, top: f64, right: f64, bottom: f64 };

pub fn center(box: Box) Point {
    return .{ .x = (box.left + box.right) / 2, .y = (box.top + box.bottom) / 2 };
}

pub fn find(page: *Page, args: Value) !?Node {
    if (string(args, "ref")) |ref| return try fromRef(page, ref);
    if (string(args, "selector")) |selector| return try fromSelector(page, selector);
    if (string(args, "role")) |role| return try fromRole(page, role, string(args, "name"));
    return null;
}

pub fn fromRef(page: *Page, ref: []const u8) !Node {
    var node: Node = .{};
    var id_text = ref;
    if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
        if (ref.len < 2 or ref[0] != 'f') return page.fail("Use a ref from the latest snapshot.", .{});
        const key = std.fmt.parseInt(u32, ref[1..dot], 10) catch return page.fail("Use a ref from the latest snapshot.", .{});
        for (try page.frames()) |f| if (f.key == key) {
            node.frame = f;
            node.session = f.session;
        };
        if (node.frame == null) return page.fail("That frame is gone. Take a new snapshot for current refs.", .{});
        id_text = ref[dot + 1 ..];
    }
    node.backend = std.fmt.parseInt(i64, id_text, 10) catch return page.fail("Use a ref from the latest snapshot.", .{});
    _ = page.devtoolsIn(node.session, "DOM.describeNode", node.params()) catch |err| {
        if (err == error.Dialog) return err;
        return page.fail("That element is no longer on the page. Take a new snapshot for current refs.", .{});
    };
    return node;
}

fn fromSelector(page: *Page, selector: []const u8) !Node {
    const needle = try std.json.Stringify.valueAlloc(page.arena, selector, .{});
    const expression = try std.fmt.allocPrint(page.arena,
        \\(() => {{ const found = document.querySelectorAll({s}); if (found.length !== 1) throw new Error("The selector matched " + found.length + " elements; it must match exactly one."); return found[0]; }})()
    , .{needle});
    const answer = try page.devtools("Runtime.evaluate", .{ .expression = expression });
    if (field(answer, "exceptionDetails")) |details| {
        const description = if (field(details, "exception")) |e| string(e, "description") else null;
        return page.fail("{s}", .{firstLine(description orelse "The selector matched nothing.")});
    }
    const result = field(answer, "result") orelse return page.fail("The selector matched nothing.", .{});
    return .{ .object = string(result, "objectId") orelse return page.fail("The selector matched nothing.", .{}) };
}

fn fromRole(page: *Page, role: []const u8, name: ?[]const u8) !Node {
    const ax = try page.devtools("Accessibility.getFullAXTree", browser_page.no_params);
    const nodes = field(ax, "nodes") orelse return page.fail("The page gave no accessibility tree.", .{});
    if (nodes != .array) return page.fail("The page gave no accessibility tree.", .{});
    var match: ?i64 = null;
    var count: usize = 0;
    for (nodes.array.items) |node| {
        if (json_read.boolean(node, "ignored") orelse false) continue;
        if (!std.mem.eql(u8, inner(node, "role") orelse "", role)) continue;
        if (name) |wanted| if (!sameName(inner(node, "name") orelse "", wanted)) continue;
        count += 1;
        const id = field(node, "backendDOMNodeId") orelse continue;
        if (id == .integer) match = id.integer;
    }
    if (count != 1 or match == null) return page.fail("{d} elements have that role and name; choose one that matches exactly one, or use a ref.", .{count});
    return .{ .backend = match };
}

fn inner(node: Value, name: []const u8) ?[]const u8 {
    const outer = field(node, name) orelse return null;
    const v = field(outer, "value") orelse return null;
    return if (v == .string) v.string else null;
}

fn sameName(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var ib = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

fn firstLine(text: []const u8) []const u8 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return if (std.mem.startsWith(u8, line, "Error: ")) line["Error: ".len..] else line;
}

pub const Quad = enum { content, border };

pub fn elementBox(page: *Page, node: Node, quad: Quad) !Box {
    _ = page.devtoolsIn(node.session, "DOM.scrollIntoViewIfNeeded", node.params()) catch |err| {
        if (err == error.Dialog) return err;
        return page.fail("That element is no longer on the page. Take a new snapshot for current refs.", .{});
    };
    const answer = try page.devtoolsIn(node.session, "DOM.getBoxModel", node.params());
    const model = field(answer, "model") orelse return page.fail("That element has no box on the page.", .{});
    const points = field(model, @tagName(quad)) orelse return page.fail("That element has no box on the page.", .{});
    if (points != .array or points.array.items.len != 8) return page.fail("That element has no box on the page.", .{});
    var b: Box = .{ .left = std.math.inf(f64), .top = std.math.inf(f64), .right = -std.math.inf(f64), .bottom = -std.math.inf(f64) };
    for (0..4) |c| {
        const x = asNumber(points.array.items[2 * c]) orelse 0;
        const y = asNumber(points.array.items[2 * c + 1]) orelse 0;
        b.left = @min(b.left, x);
        b.right = @max(b.right, x);
        b.top = @min(b.top, y);
        b.bottom = @max(b.bottom, y);
    }
    const offset = if (node.frame) |f| try frameOffset(page, f, 0) else Point{ .x = 0, .y = 0 };
    return .{ .left = b.left + offset.x, .top = b.top + offset.y, .right = b.right + offset.x, .bottom = b.bottom + offset.y };
}

fn frameOffset(page: *Page, frame: browser_page.Frame, depth: u32) !Point {
    if (depth > 8) return .{ .x = 0, .y = 0 };
    const owner = try page.devtoolsIn(frame.parent, "DOM.getFrameOwner", .{ .frameId = frame.target });
    const id = number(owner, "backendNodeId") orelse return page.fail("Couldn't find where that frame sits.", .{});
    const answer = try page.devtoolsIn(frame.parent, "DOM.getBoxModel", .{ .backendNodeId = @as(i64, @intFromFloat(id)) });
    const model = field(answer, "model") orelse return page.fail("Couldn't find where that frame sits.", .{});
    const content = field(model, "content") orelse return page.fail("Couldn't find where that frame sits.", .{});
    if (content != .array or content.array.items.len < 2) return page.fail("Couldn't find where that frame sits.", .{});
    var at: Point = .{ .x = asNumber(content.array.items[0]) orelse 0, .y = asNumber(content.array.items[1]) orelse 0 };
    for (try page.frames()) |f| if (std.mem.eql(u8, f.session, frame.parent)) {
        const above = try frameOffset(page, f, depth + 1);
        at.x += above.x;
        at.y += above.y;
    };
    return at;
}

pub fn objectId(page: *Page, node: Node) ![]const u8 {
    if (node.object) |id| return id;
    const resolved = try page.devtoolsIn(node.session, "DOM.resolveNode", node.params());
    const object = field(resolved, "object") orelse return page.fail("That element is no longer on the page.", .{});
    return string(object, "objectId") orelse page.fail("That element is no longer on the page.", .{});
}

pub const Aim = struct { at: Point, box: ?Box = null };

pub fn aim(page: *Page, args: Value, verb: []const u8) !Aim {
    if (try find(page, args)) |node| {
        const b = try elementBox(page, node, .content);
        return .{ .at = center(b), .box = b };
    }
    const x = number(args, "x") orelse return page.fail("Choose an element by ref, selector or role, or x/y coordinates to {s}.", .{verb});
    const y = number(args, "y") orelse return page.fail("Choose an element by ref, selector or role, or x/y coordinates to {s}.", .{verb});
    return .{ .at = .{ .x = x, .y = y } };
}

pub fn call(page: *Page, node: Node, function: []const u8, argument: ?[]const u8) !Value {
    const id = try objectId(page, node);
    const answer = if (argument) |a|
        try page.devtoolsIn(node.session, "Runtime.callFunctionOn", .{ .objectId = id, .functionDeclaration = function, .returnByValue = true, .arguments = .{.{ .value = a }} })
    else
        try page.devtoolsIn(node.session, "Runtime.callFunctionOn", .{ .objectId = id, .functionDeclaration = function, .returnByValue = true });
    if (field(answer, "exceptionDetails")) |details| {
        const description = if (field(details, "exception")) |e| string(e, "description") else null;
        return page.fail("{s}", .{firstLine(description orelse "The page refused.")});
    }
    const result = field(answer, "result") orelse return .null;
    return field(result, "value") orelse .null;
}

pub const select_contents =
    \\function () {
    \\  if (typeof this.select === "function") { this.select(); return; }
    \\  if (!(this instanceof HTMLElement) || !this.isContentEditable) return;
    \\  const range = document.createRange();
    \\  range.selectNodeContents(this);
    \\  const selection = getSelection();
    \\  selection.removeAllRanges();
    \\  selection.addRange(range);
    \\}
;

pub const choose_option =
    \\function (choice) {
    \\  if (!(this instanceof HTMLSelectElement)) throw new Error("That element is not a dropdown");
    \\  const options = [...this.options];
    \\  const option = options.find((o) => o.value === choice) || options.find((o) => o.text.trim() === choice.trim());
    \\  if (!option) throw new Error("No option matches " + choice + ". Options: " + options.map((o) => o.text.trim()).join(", "));
    \\  this.value = option.value;
    \\  this.dispatchEvent(new Event("input", { bubbles: true }));
    \\  this.dispatchEvent(new Event("change", { bubbles: true }));
    \\  return option.text.trim();
    \\}
;
