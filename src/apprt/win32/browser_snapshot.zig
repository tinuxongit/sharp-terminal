//! The page as text for Claude: DevTools' accessibility tree as indented
//! lines with each element's role, name, value, states and a [ref=N] that
//! browser_action can target. Empty containers and text repeating a
//! nearby label are left out. Ported from Citropy's snapshot-tree.ts.
const std = @import("std");
const Value = std.json.Value;
const json_read = @import("json_read.zig");
const field = json_read.field;
const string = json_read.string;

/// Longer trees are cut, pointing at ref to read the rest.
pub const max_length = 28_000;

/// Roles never shown, and roles shown only when they carry a name or value.
const skipped_roles = [_][]const u8{ "InlineTextBox", "LineBreak" };
const silent_roles = [_][]const u8{
    "generic", "image",    "none",    "StaticText", "paragraph",   "group",   "LabelText",
    "list",    "listitem", "section", "Section",    "RootWebArea", "WebArea",
};
const reported_states = [_][]const u8{ "focused", "disabled", "checked", "pressed", "selected", "expanded", "required", "invalid" };

const Tree = struct {
    nodes: []const Value,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    out: *std.Io.Writer,
};

/// Write the tree of Accessibility.getFullAXTree's `nodes`, or only the
/// element whose ref is `root_ref`.
pub fn write(alloc: std.mem.Allocator, nodes: []const Value, root_ref: ?[]const u8, out: *std.Io.Writer) !void {
    var tree: Tree = .{ .nodes = nodes, .out = out };
    defer tree.by_id.deinit(alloc);
    var has_parent: std.StringHashMapUnmanaged(void) = .empty;
    defer has_parent.deinit(alloc);
    for (nodes, 0..) |node, i| {
        const id = string(node, "nodeId") orelse continue;
        try tree.by_id.put(alloc, id, i);
        const children = field(node, "childIds") orelse continue;
        if (children != .array) continue;
        for (children.array.items) |child| if (child == .string) try has_parent.put(alloc, child.string, {});
    }
    for (nodes) |node| {
        const is_root = if (root_ref) |ref|
            isRef(node, ref)
        else
            !has_parent.contains(string(node, "nodeId") orelse continue);
        if (!is_root) continue;
        var names: Names = .empty;
        defer names.deinit(alloc);
        try walk(alloc, &tree, node, 0, &names, root_ref);
    }
}

const Names = std.StringHashMapUnmanaged(void);

fn walk(alloc: std.mem.Allocator, tree: *Tree, node: Value, depth: usize, nearby: *const Names, root_ref: ?[]const u8) !void {
    const role = roleOf(node);
    const name = nameOf(node);
    const repeats = std.mem.eql(u8, role, "StaticText") and name.len > 0 and nearby.contains(name);
    const shown = !repeats and (visible(node) or (root_ref != null and isRef(node, root_ref.?)));
    if (shown) try line(tree.out, node, depth);

    // Text that repeats this element's name or a sibling's label is noise.
    var names: Names = .empty;
    defer names.deinit(alloc);
    if (shown) {
        if (name.len > 0) try names.put(alloc, name, {});
    } else {
        var it = nearby.keyIterator();
        while (it.next()) |k| try names.put(alloc, k.*, {});
    }
    const children = field(node, "childIds") orelse return;
    if (children != .array) return;
    for (children.array.items) |id| {
        const child = tree.nodes[tree.by_id.get(if (id == .string) id.string else continue) orelse continue];
        const label = nameOf(child);
        if (label.len > 0 and !std.mem.eql(u8, roleOf(child), "StaticText")) try names.put(alloc, label, {});
    }
    for (children.array.items) |id| {
        const child = tree.nodes[tree.by_id.get(if (id == .string) id.string else continue) orelse continue];
        try walk(alloc, tree, child, if (shown) depth + 1 else depth, &names, root_ref);
    }
}

fn visible(node: Value) bool {
    if (json_read.boolean(node, "ignored") orelse false) return false;
    const role = roleOf(node);
    if (oneOf(role, &skipped_roles)) return false;
    return nameOf(node).len > 0 or hasValue(node) or !oneOf(role, &silent_roles);
}

fn line(w: *std.Io.Writer, node: Value, depth: usize) !void {
    try w.splatByteAll(' ', depth * 2);
    try w.writeAll(roleOf(node));
    const name = nameOf(node);
    if (name.len > 0) {
        try w.writeByte(' ');
        try std.json.Stringify.encodeJsonString(name, .{}, w);
    }
    if (hasValue(node)) {
        try w.writeAll(" value=");
        try std.json.Stringify.value(inner(node, "value").?, .{}, w);
    }
    var first = true;
    if (field(node, "properties")) |props| if (props == .array) for (props.array.items) |prop| {
        const prop_name = string(prop, "name") orelse continue;
        if (!oneOf(prop_name, &reported_states)) continue;
        const v = inner(prop, "value");
        const text: ?[]const u8 = if (std.mem.eql(u8, prop_name, "expanded"))
            (if (truthy(v)) "expanded" else "collapsed")
        else if (truthy(v))
            prop_name
        else
            null;
        const mixed = v != null and v.? == .string and std.mem.eql(u8, v.?.string, "mixed");
        if (text == null and !mixed) continue;
        try w.writeAll(if (first) " (" else ", ");
        first = false;
        if (mixed) try w.print("{s}=mixed", .{prop_name}) else try w.writeAll(text.?);
    };
    if (!first) try w.writeByte(')');
    if (string(node, "ref")) |ref| {
        try w.print(" [ref={s}]", .{ref});
    } else if (backendId(node)) |id| try w.print(" [ref={d}]", .{id});
    try w.writeByte('\n');
}

fn isRef(node: Value, ref: []const u8) bool {
    if (string(node, "ref")) |own| return std.mem.eql(u8, own, ref);
    const id = backendId(node) orelse return false;
    return (std.fmt.parseInt(i64, ref, 10) catch return false) == id;
}

fn roleOf(node: Value) []const u8 {
    const v = inner(node, "role") orelse return "";
    return if (v == .string) v.string else "";
}

fn nameOf(node: Value) []const u8 {
    const v = inner(node, "name") orelse return "";
    return if (v == .string) std.mem.trim(u8, v.string, " \t\r\n") else "";
}

fn hasValue(node: Value) bool {
    const v = inner(node, "value") orelse return false;
    return switch (v) {
        .null => false,
        .string => |s| s.len > 0,
        else => true,
    };
}

pub fn backendId(node: Value) ?i64 {
    const v = field(node, "backendDOMNodeId") orelse return null;
    return if (v == .integer) v.integer else null;
}

fn truthy(v: ?Value) bool {
    const value = v orelse return false;
    return switch (value) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

/// `node[name].value`, the shape DevTools wraps most AX fields in.
fn inner(node: Value, name: []const u8) ?Value {
    const outer = field(node, name) orelse return null;
    return field(outer, "value");
}

fn oneOf(s: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, s, item)) return true;
    return false;
}
