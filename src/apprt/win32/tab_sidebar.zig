//! Tabs as a list beside the terminal (`window-tab-bar-position = sidebar`):
//! a search box, then sections for where shells run (local, WSL, SSH
//! servers), groups for each folder (or server), and the tabs themselves.
//! Layout and painting only; Window handles input.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const profiles = @import("profiles.zig");
const SearchField = @import("SearchField.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

/// Sizes in pixels at 96 DPI.
pub const default_width = 260.0;
pub const min_width = 180.0;
pub const max_width = 600.0;
const pad = 10.0;
const search_height = 34.0;
const section_height = 30.0;
const group_height = 30.0;
const item_height = 32.0;
const item_indent = 22.0;
const icon_size = 16.0;
const corner = 6.0;
const dot_size = 8.0;
const side_column = 34.0;
const button_size = 24.0;
const resize_grip = 5.0;

const icon_folder = 0xE8B7;
const icon_folder_open = 0xE838;
const icon_server = 0xE774;
const icon_close = 0xE8BB;
const icon_add = 0xE710;

/// Bell red, as in the sidebar this mirrors.
const attention_red: Rgb = .{ .r = 0xE5, .g = 0x48, .b = 0x3E };

pub const Section = enum { local, wsl, servers };

pub const Item = struct {
    tab: usize,
    /// The title, converted to UTF-8 for drawing and search.
    title: []const u8,
    icon: ?w32.HICON,
    section: Section,
    /// What the tab is grouped by: its folder's full path, or the SSH
    /// host for servers.
    group: []const u8,
    /// How the group is labelled: the folder's name, or the host.
    group_label: []const u8,
    age_ms: u64,
    attention: bool,
};

pub const Target = union(enum) {
    none,
    search,
    /// The right edge: dragging it resizes the sidebar.
    resize,
    tab: usize,
    close: usize,
    /// A group header, named by the first tab in it: toggles collapse.
    group: usize,
    /// The "+" on a group header: a new tab in that folder.
    group_new: usize,
    /// A section title, which shows its "+" while hovered.
    section: Section,
    /// The "+" on a section title: a new tab in a folder the user picks.
    section_new: Section,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Spots = @import("spots.zig").Spots(Target, 200);

pub const Fonts = struct {
    item: ?*anyopaque = null,
    item_strong: ?*anyopaque = null,
    small: ?*anyopaque = null,
    icons: ?*anyopaque = null,
    icons_small: ?*anyopaque = null,

    pub fn init(hdc: w32.HDC, scale: f32) Fonts {
        const ui = canvas_mod.jetbrains_mono;
        const icon_face = canvas_mod.iconFace(hdc);
        const f = canvas_mod.createFont;
        return .{
            .item = f(13, scale, ui, w32.FW_NORMAL, .cleartype),
            .item_strong = f(13, scale, ui, w32.FW_BOLD, .cleartype),
            .small = f(12, scale, ui, w32.FW_NORMAL, .cleartype),
            .icons = f(14, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_small = f(9, scale, icon_face, w32.FW_NORMAL, .grayscale),
        };
    }

    pub fn deinit(self: *Fonts) void {
        inline for (.{ &self.item, &self.item_strong, &self.small, &self.icons, &self.icons_small }) |font| {
            if (font.*) |f| _ = w32.DeleteObject(f);
            font.* = null;
        }
    }
};

pub const State = struct {
    items: []const Item,
    active: usize,
    hover: Target,
    search: *const SearchField,
    window_focused: bool,
    scroll: i32,
    /// Group keys the user folded away.
    collapsed: []const []const u8,
    /// The tab being dragged, drawn as lifted.
    dragging: ?usize = null,
};

/// How a folded group is remembered: the same folder can hold both local
/// and WSL tabs, folded separately.
pub fn collapseKey(buf: []u8, section: Section, group: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}", .{ @tagName(section), group }) catch group;
}

pub fn sameGroup(a: []const u8, b: []const u8) bool {
    // Windows paths ignore case.
    return std.ascii.eqlIgnoreCase(a, b);
}

fn px(value: f32, scale: f32) i32 {
    return @intFromFloat(@round(value * scale));
}

const Painter = struct {
    c: Canvas,
    s: f32,
    palette: tab_strip.Palette,
    fonts: Fonts,
    state: State,
    spots: *Spots,
    list_top: i32,

    fn px(self: Painter, value: f32) i32 {
        return @intFromFloat(@round(value * self.s));
    }
};

/// Paint the sidebar into `c`, which covers exactly the sidebar, and
/// return how far its list can scroll.
pub fn paint(c: Canvas, scale: f32, palette: tab_strip.Palette, fonts: Fonts, state: State, spots: *Spots) i32 {
    spots.len = 0;
    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = c.height }, palette.strip);

    const search_rect: w32.RECT = .{ .left = px(pad, scale), .top = px(pad, scale), .right = c.width - px(pad, scale), .bottom = px(pad + search_height, scale) };
    const list_top = search_rect.bottom + px(pad, scale);
    var p: Painter = .{ .c = c, .s = scale, .palette = palette, .fonts = fonts, .state = state, .spots = spots, .list_top = list_top };

    // The list first, so the search area covers what scrolls under it.
    var y = list_top - state.scroll;
    for ([_]Section{ .local, .wsl, .servers }) |section| {
        if (!sectionHasItems(state, section)) continue;
        y = paintSection(&p, section, y);
        // Groups in the order their first tab appears.
        for (state.items, 0..) |first, i| {
            if (first.section != section or !visible(state, first)) continue;
            if (seenGroupBefore(state, state.items[0..i], first)) continue;
            const folded = isCollapsed(state, first);
            y = paintGroup(&p, first, folded, y);
            if (folded) continue;
            for (state.items) |item| {
                if (item.section != section or !visible(state, item) or !sameGroup(item.group, first.group)) continue;
                y = paintItem(&p, item, y);
            }
        }
    }
    const content_height = y + state.scroll - list_top;

    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = list_top }, palette.strip);
    state.search.paint(c, search_rect, scale, .{
        .fill = palette.strip.mix(palette.contrast, 0.06),
        .hover = palette.hover,
        .focused = palette.hover.mix(palette.contrast, 0.05),
        .text = palette.text,
        .text_dim = palette.text_dim,
        .font = fonts.item,
        .icon_font = fonts.icons_small,
        .placeholder = profiles.data.sidebar.search_placeholder,
    }, state.hover.eql(.search), state.window_focused);
    spots.add(search_rect, .search);

    // The grip goes last so it wins over rows near the edge.
    const grip: w32.RECT = .{ .left = c.width - px(resize_grip, scale), .top = 0, .right = c.width, .bottom = c.height };
    if (state.hover.eql(.resize)) c.fill(.{ .left = c.width - px(2, scale), .top = 0, .right = c.width, .bottom = c.height }, palette.separator);
    spots.add(grip, .resize);

    return @max(0, content_height - (c.height - list_top));
}

fn visible(state: State, item: Item) bool {
    const query = state.search.text();
    return query.len == 0 or SearchField.matches(item.title, query) or SearchField.matches(item.group_label, query);
}

fn isCollapsed(state: State, item: Item) bool {
    // Searching shows every match, folded or not.
    if (state.search.len > 0) return false;
    var buf: [300]u8 = undefined;
    const wanted = collapseKey(&buf, item.section, item.group);
    for (state.collapsed) |key| {
        if (sameGroup(key, wanted)) return true;
    }
    return false;
}

fn sectionHasItems(state: State, section: Section) bool {
    for (state.items) |item| {
        if (item.section == section and visible(state, item)) return true;
    }
    return false;
}

fn seenGroupBefore(state: State, earlier: []const Item, item: Item) bool {
    for (earlier) |e| {
        if (e.section == item.section and visible(state, e) and sameGroup(e.group, item.group)) return true;
    }
    return false;
}

fn groupHoldsActive(state: State, group: Item) bool {
    for (state.items) |item| {
        if (item.tab == state.active and item.section == group.section and sameGroup(item.group, group.group)) return true;
    }
    return false;
}

/// A section title followed by a rule to the right edge, and while
/// hovered a "+" that opens a tab in a chosen folder.
fn paintSection(p: *Painter, section: Section, y: i32) i32 {
    const title = switch (section) {
        .local => profiles.data.sidebar.local,
        .wsl => profiles.data.sidebar.wsl,
        .servers => profiles.data.sidebar.servers,
    };
    const h = p.px(section_height);
    const left = p.px(pad + 6);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    p.c.text(.{ .left = left, .top = y, .right = row.right, .bottom = y + h }, title, p.fonts.small, p.palette.text_dim, .left);

    // A server's tabs come from SSH itself, so it has no "+".
    const can_add = section != .servers;
    const hovered = can_add and (p.state.hover.eql(.{ .section = section }) or p.state.hover.eql(.{ .section_new = section }));
    const button = p.px(button_size);
    const add: w32.RECT = .{ .left = row.right - p.px(4) - button, .top = y + @divTrunc(h - button, 2), .right = row.right - p.px(4), .bottom = y + @divTrunc(h - button, 2) + button };

    const rule_left = left + p.c.textWidth(title, p.fonts.small) + p.px(10);
    const rule_right = if (hovered) add.left - p.px(6) else row.right - p.px(6);
    const mid = y + @divTrunc(h, 2);
    if (rule_right > rule_left) p.c.fill(.{ .left = rule_left, .top = mid, .right = rule_right, .bottom = mid + 1 }, p.palette.separator);

    if (can_add) p.spots.add(clip(row, p.list_top), .{ .section = section });
    if (hovered) {
        if (p.state.hover.eql(.{ .section_new = section })) p.c.fillRounded(add, p.px(corner), p.palette.hover);
        p.c.glyph(add, icon_add, p.fonts.icons_small, p.palette.text);
        p.spots.add(clip(add, p.list_top), .{ .section_new = section });
    }
    return y + h;
}

fn paintGroup(p: *Painter, first: Item, folded: bool, y: i32) i32 {
    const h = p.px(group_height);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    const hovered = p.state.hover.eql(.{ .group = first.tab }) or p.state.hover.eql(.{ .group_new = first.tab });
    if (hovered) p.c.fillRounded(row, p.px(corner), p.palette.hover);

    const active = groupHoldsActive(p.state, first);
    const color = if (active or hovered) p.palette.text else p.palette.text_dim;
    const left = p.px(pad + 6);
    const icon: u16 = if (first.section == .servers) icon_server else if (folded) icon_folder else icon_folder_open;
    p.c.glyph(.{ .left = left, .top = y, .right = left + p.px(icon_size), .bottom = y + h }, icon, p.fonts.icons, color);

    const button = p.px(button_size);
    const add: w32.RECT = .{ .left = row.right - p.px(4) - button, .top = y + @divTrunc(h - button, 2), .right = row.right - p.px(4), .bottom = y + @divTrunc(h - button, 2) + button };
    const label_right = if (hovered) add.left - p.px(4) else row.right - p.px(4);
    p.c.text(.{ .left = left + p.px(icon_size + 8), .top = y, .right = label_right, .bottom = y + h }, first.group_label, if (active) p.fonts.item_strong else p.fonts.item, color, .left);

    p.spots.add(clip(row, p.list_top), .{ .group = first.tab });
    // New tabs open in a folder; a server's tabs come from SSH itself.
    if (hovered and first.section != .servers) {
        if (p.state.hover.eql(.{ .group_new = first.tab })) p.c.fillRounded(add, p.px(corner), p.palette.hover.mix(p.palette.contrast, 0.1));
        p.c.glyph(add, icon_add, p.fonts.icons_small, p.palette.text);
        p.spots.add(clip(add, p.list_top), .{ .group_new = first.tab });
    }
    return y + h;
}

fn paintItem(p: *Painter, item: Item, y: i32) i32 {
    const h = p.px(item_height);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    const active = item.tab == p.state.active;
    const dragged = p.state.dragging == item.tab;
    const hovered = !dragged and (p.state.hover.eql(.{ .tab = item.tab }) or p.state.hover.eql(.{ .close = item.tab }));
    if (dragged) {
        p.c.fillRounded(row, p.px(corner), p.palette.hover.mix(p.palette.contrast, 0.08));
    } else if (active) {
        p.c.fillRounded(row, p.px(corner), p.palette.active_tab);
    } else if (hovered) {
        p.c.fillRounded(row, p.px(corner), p.palette.hover);
    }

    const icon_left = row.left + p.px(item_indent);
    const size = p.px(icon_size);
    if (item.icon) |icon| {
        p.c.sync();
        _ = w32.DrawIconEx(p.c.hdc, icon_left, y + @divTrunc(h - size, 2), icon, size, size, 0, null, w32.DI_NORMAL);
    }
    const side: w32.RECT = .{ .left = row.right - p.px(side_column), .top = y, .right = row.right - p.px(4), .bottom = y + h };
    const title_color = if (active or hovered or dragged) p.palette.text else p.palette.text_dim;
    p.c.text(.{ .left = icon_left + size + p.px(10), .top = y, .right = side.left - p.px(4), .bottom = y + h }, item.title, p.fonts.item, title_color, .left);

    // The right column shows, in order of priority: close on hover, the
    // bell dot, or how long ago the tab opened.
    const button = p.px(button_size);
    const close: w32.RECT = .{ .left = side.right - button, .top = y + @divTrunc(h - button, 2), .right = side.right, .bottom = y + @divTrunc(h - button, 2) + button };
    if (hovered) {
        if (p.state.hover.eql(.{ .close = item.tab })) p.c.fillRounded(close, @divTrunc(button, 2), p.palette.hover.mix(p.palette.contrast, 0.1));
        p.c.glyph(close, icon_close, p.fonts.icons_small, p.palette.text);
    } else if (item.attention) {
        const d = p.px(dot_size);
        const dot: w32.RECT = .{ .left = side.right - p.px(10) - d, .top = y + @divTrunc(h - d, 2), .right = side.right - p.px(10), .bottom = y + @divTrunc(h - d, 2) + d };
        p.c.fillRounded(dot, @divTrunc(d, 2), attention_red);
    } else {
        var buf: [8]u8 = undefined;
        p.c.text(side, age(&buf, item.age_ms), p.fonts.small, p.palette.text_dim, .right);
    }
    p.spots.add(clip(row, p.list_top), .{ .tab = item.tab });
    // Added after the row so it wins the hit test.
    if (hovered) p.spots.add(clip(close, p.list_top), .{ .close = item.tab });
    return y + h;
}

/// Rows that scrolled under the search box can't be clicked there.
fn clip(rect: w32.RECT, top: i32) w32.RECT {
    var r = rect;
    r.top = @max(r.top, top);
    if (r.bottom < r.top) r.bottom = r.top;
    return r;
}

/// "now", "5m", "3h", "2d" or "1w", like the list this mirrors.
fn age(buf: []u8, ms: u64) []const u8 {
    const minutes = ms / 60_000;
    if (minutes < 1) return "now";
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "";
    const hours = minutes / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "";
    const days = hours / 24;
    if (days < 7) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
    return std.fmt.bufPrint(buf, "{d}w", .{days / 7}) catch "";
}
