//! Split panes inside a tab: the dividers between them (painting and
//! dragging), and creating, moving between, resizing, equalizing and
//! zooming splits.
const std = @import("std");
const termio = @import("../../termio.zig");
const apprt = @import("../../apprt.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const Window = @import("Window.zig");

/// Paint divider lines between split panes in the active tab.
pub fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    paintDividerNode(self, hdc, tree, .root, rect);
}

pub fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                paintDividerNode(self, hdc, tree, s.left, left_rect);
                paintDividerNode(self, hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                paintDividerNode(self, hdc, tree, s.left, top_rect);
                paintDividerNode(self, hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};

pub fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return hitTestDividerNode(self, tree, .root, rect, x, y);
}

pub fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return hitTestDividerNode(self, tree, s.left, left_rect, x, y) orelse
                    hitTestDividerNode(self, tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return hitTestDividerNode(self, tree, s.left, top_rect, x, y) orelse
                    hitTestDividerNode(self, tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

pub fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

pub fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

pub fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// Create a new split in the active tab.
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);
    new_surface.tab_color = active_surface.tab_color;

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new surface.
    self.tab_active_surface[tab] = new_surface;

    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    // In a window narrower than the step the ratio passes 1, which the
    // tree asserts against.
    const delta: f16 = @floatCast(std.math.clamp(sign * @as(f32, @floatFromInt(rs.amount)) / dimension, -1.0, 1.0));

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

/// Windows Terminal's pane actions on the pane the action came from
/// (Ghostty's split_pane, which Sharp adds). Not the active tab's focused
/// pane: the action runs inside that pane's key handling, which must not
/// see it freed (close_others would close it when the two differ).
pub fn arrange(focused: *Surface, action: apprt.action.SplitPane) void {
    const self = focused.parent_window;
    const tab = self.findTabIndex(focused) orelse return;
    switch (action) {
        .swap_next => swap(self, tab, focused, .next),
        .swap_previous => swap(self, tab, focused, .previous),
        .flip => flip(self, tab, focused),
        .to_new_tab => toNewTab(self, tab, focused),
        .close_others => closeOthers(self, tab, focused),
        .broadcast => {
            const on = !focused.broadcast;
            var it = self.tab_trees[tab].iterator();
            while (it.next()) |entry| entry.view.broadcast = on;
            self.invalidateTabBar();
        },
    }
}

/// A copy of tab `tab`'s tree to change before it replaces the old one.
/// The copy holds its own references to the same panes, so moving them
/// around or changing a split's layout in it keeps every count right.
fn editable(self: *Window, tab: usize) ?struct { tree: SplitTree(Surface), nodes: []SplitTree(Surface).Node } {
    const tree = self.tab_trees[tab].clone(self.app.core_app.alloc) catch return null;
    return .{ .tree = tree, .nodes = @constCast(tree.nodes) };
}

fn replaceTree(self: *Window, tab: usize, tree: SplitTree(Surface)) void {
    var old = self.tab_trees[tab];
    self.tab_trees[tab] = tree;
    old.deinit();
    self.layoutSplits();
    self.invalidateTabBar();
}

fn swap(self: *Window, tab: usize, focused: *Surface, direction: enum { next, previous }) void {
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return;
    const from = self.findHandle(tab, focused) orelse return;
    // The panes in order, wrapping around at either end as in Windows
    // Terminal.
    var leaves: [64]SplitTree(Surface).Node.Handle = undefined;
    var count: usize = 0;
    var at: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (count == leaves.len) break;
        if (entry.handle == from) at = count;
        leaves[count] = entry.handle;
        count += 1;
    }
    const to = leaves[switch (direction) {
        .next => (at + 1) % count,
        .previous => (at + count - 1) % count,
    }];
    const copy = editable(self, tab) orelse return;
    std.mem.swap(SplitTree(Surface).Node, &copy.nodes[from.idx()], &copy.nodes[to.idx()]);
    replaceTree(self, tab, copy.tree);
}

fn flip(self: *Window, tab: usize, focused: *Surface) void {
    if (!self.tab_trees[tab].isSplit()) return;
    const leaf = self.findHandle(tab, focused) orelse return;
    const copy = editable(self, tab) orelse return;
    // The split that holds the focused pane directly.
    for (copy.nodes) |*node| switch (node.*) {
        .leaf => {},
        .split => |*s| if (s.left == leaf or s.right == leaf) {
            s.layout = if (s.layout == .horizontal) .vertical else .horizontal;
            break;
        },
    };
    replaceTree(self, tab, copy.tree);
}

fn toNewTab(self: *Window, tab: usize, focused: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return;
    const handle = self.findHandle(tab, focused) orelse return;
    const next = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null) orelse return;
    const next_surface = switch (tree.nodes[next.idx()]) {
        .leaf => |v| v,
        .split => return,
    };
    // The pane's own tree takes a reference before the old tree lets go.
    var alone = SplitTree(Surface).init(alloc, focused) catch return;
    const rest = tree.remove(alloc, handle) catch {
        alone.deinit();
        return;
    };
    self.tab_active_surface[tab] = next_surface;
    replaceTree(self, tab, rest);
    self.putTab(tab + 1, .{ .tree = alone, .active = focused, .title = self.tab_titles[tab], .title_len = self.tab_title_lens[tab] });
    self.selectTabIndex(tab + 1);
    self.updateTabBarVisibility();
}

fn closeOthers(self: *Window, tab: usize, focused: *Surface) void {
    var others: [64]*Surface = undefined;
    var count: usize = 0;
    var running = false;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        if (entry.view == focused or count == others.len) continue;
        others[count] = entry.view;
        count += 1;
        if (entry.view.core_surface_ready and entry.view.core_surface.needsConfirmQuit()) running = true;
    }
    if (count == 0) return;
    if (running and !Window.confirmDialog(self.hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Commands are still running in the other splits.\nClose them anyway?"))) return;
    for (others[0..count]) |surface| self.closeSplitSurface(surface);
}

/// Send what was typed in `from` to the other panes of its tab too, when
/// the tab broadcasts (split_pane:broadcast), as Windows Terminal does.
pub fn broadcastInput(from: *Surface, bytes: []const u8) void {
    if (!from.broadcast) return;
    const window = from.parent_window;
    const tab = window.findTabIndex(from) orelse return;
    var it = window.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        const pane = entry.view;
        if (pane == from or !pane.core_surface_ready or pane.core_surface.readonly) continue;
        const msg = termio.Message.writeReq(window.app.core_app.alloc, bytes) catch continue;
        pane.core_surface.io.queueMessage(msg, .unlocked);
    }
}
