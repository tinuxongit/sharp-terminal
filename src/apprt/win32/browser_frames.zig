const std = @import("std");
const Value = std.json.Value;
const browser_page = @import("browser_page.zig");
const json_read = @import("json_read.zig");
const Page = browser_page.Page;
const field = json_read.field;
const string = json_read.string;

const max_frames = 24;

pub fn tree(page: *Page) !std.ArrayList(Value) {
    const ax = try page.devtools("Accessibility.getFullAXTree", browser_page.no_params);
    const nodes = field(ax, "nodes") orelse return page.fail("The page gave no accessibility tree.", .{});
    if (nodes != .array) return page.fail("The page gave no accessibility tree.", .{});
    var all: std.ArrayList(Value) = .empty;
    try all.appendSlice(page.arena, nodes.array.items);
    var read: usize = 0;
    var i: usize = 0;
    while (i < all.items.len and read < max_frames) : (i += 1) {
        const node = all.items[i];
        if (!std.mem.eql(u8, role(node), "Iframe")) continue;
        const id = field(node, "backendDOMNodeId") orelse continue;
        if (id != .integer) continue;
        if (try readFrame(page, &all, i, id.integer)) read += 1;
    }
    return all;
}

fn role(node: Value) []const u8 {
    const outer = field(node, "role") orelse return "";
    return string(outer, "value") orelse "";
}

fn readFrame(page: *Page, all: *std.ArrayList(Value), index: usize, backend: i64) !bool {
    const iframe = all.items[index];
    const session = string(iframe, "sharpSession") orelse "";
    const described = page.devtoolsIn(session, "DOM.describeNode", .{ .backendNodeId = backend }) catch |err| {
        if (err == error.Dialog) return err;
        page.failure = null;
        return false;
    };
    const frame_id = string(field(described, "node") orelse return false, "frameId") orelse return false;
    var inner = try frameNodes(page, session, frame_id);
    var inner_session = session;
    var prefix = string(iframe, "sharpPrefix") orelse "";
    if (inner.len <= 1) {
        for (try page.frames()) |f| if (std.mem.eql(u8, f.target, frame_id)) {
            inner = try frameNodes(page, f.session, null);
            inner_session = f.session;
            prefix = try std.fmt.allocPrint(page.arena, "f{d}.", .{f.key});
        };
    }
    if (inner.len == 0) return false;
    var root: ?[]const u8 = null;
    for (inner) |*node| {
        try scope(page, node, frame_id, inner_session, prefix);
        if (root == null and field(node.*, "parentId") == null) root = string(node.*, "nodeId");
    }
    const root_id = root orelse string(inner[0], "nodeId") orelse return false;
    if (iframe != .object) return false;
    var children = std.json.Array.init(page.arena);
    if (field(iframe, "childIds")) |existing| if (existing == .array) try children.appendSlice(existing.array.items);
    try children.append(.{ .string = root_id });
    try all.items[index].object.put(page.arena, "childIds", .{ .array = children });
    try all.appendSlice(page.arena, inner);
    return true;
}

fn frameNodes(page: *Page, session: []const u8, frame_id: ?[]const u8) ![]Value {
    const answer = (if (frame_id) |id|
        page.devtoolsIn(session, "Accessibility.getFullAXTree", .{ .frameId = id })
    else
        page.devtoolsIn(session, "Accessibility.getFullAXTree", browser_page.no_params)) catch |err| {
        if (err == error.Dialog) return err;
        page.failure = null;
        return page.arena.alloc(Value, 0);
    };
    const nodes = field(answer, "nodes") orelse return page.arena.alloc(Value, 0);
    return if (nodes == .array) nodes.array.items else page.arena.alloc(Value, 0);
}

fn scope(page: *Page, node: *Value, frame_id: []const u8, session: []const u8, prefix: []const u8) !void {
    if (node.* != .object) return;
    const map = &node.object;
    if (string(node.*, "nodeId")) |id| try map.put(page.arena, "nodeId", .{ .string = try scoped(page, frame_id, id) });
    if (string(node.*, "parentId")) |id| try map.put(page.arena, "parentId", .{ .string = try scoped(page, frame_id, id) });
    if (field(node.*, "childIds")) |children| if (children == .array) {
        var list = std.json.Array.init(page.arena);
        for (children.array.items) |child| if (child == .string) try list.append(.{ .string = try scoped(page, frame_id, child.string) });
        try map.put(page.arena, "childIds", .{ .array = list });
    };
    try map.put(page.arena, "sharpSession", .{ .string = session });
    try map.put(page.arena, "sharpPrefix", .{ .string = prefix });
    if (prefix.len > 0) if (field(node.*, "backendDOMNodeId")) |id| if (id == .integer) {
        try map.put(page.arena, "ref", .{ .string = try std.fmt.allocPrint(page.arena, "{s}{d}", .{ prefix, id.integer }) });
    };
}

fn scoped(page: *Page, frame_id: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(page.arena, "{s}:{s}", .{ frame_id, id });
}
