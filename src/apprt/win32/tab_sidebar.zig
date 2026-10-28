//! Tabs as a list beside the terminal (`window-tab-bar-position = sidebar`):
//! a search box, then sections for where shells run (local, WSL), groups
//! for the folder each tab is in, and the tabs themselves. Layout and
//! painting only; Window handles input.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const profiles = @import("profiles.zig");
const SearchField = @import("SearchField.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

/// Sizes in pixels at 96 DPI.
const sidebar_width = 260.0;
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

const icon_folder = 0xE8B7;
const icon_close = 0xE8BB;

/// Bell red, as in the sidebar this mirrors.
const attention_red: Rgb = .{ .r = 0xE5, .g = 0x48, .b = 0x3E };

pub fn width(scale: f32) i32 {
    return px(sidebar_width, scale);
}

fn px(value: f32, scale: f32) i32 {
    return @intFromFloat(@round(value * scale));
}

pub const Item = struct {
    tab: usize,
    /// The title, converted to UTF-8 for drawing and search.
    title: []const u8,
    icon: ?w32.HICON,
    /// The tab's folder, or its shell's name when the shell doesn't
    /// report its folder.
    group: []const u8,
    wsl: bool,
    age_ms: u64,
    attention: bool,
};

pub const Target = union(enum) {
    none,
    search,
    tab: usize,
    close: usize,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Spots = @import("spots.zig").Spots(Target, 160);

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
};

/// Paint the sidebar into `c`, which covers exactly the sidebar, and
/// return how far its list can scroll.
pub fn paint(c: Canvas, scale: f32, palette: tab_strip.Palette, fonts: Fonts, state: State, spots: *Spots) i32 {
    spots.len = 0;
    const s = scale;
    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = c.height }, palette.strip);

    const search_rect: w32.RECT = .{ .left = px(pad, s), .top = px(pad, s), .right = c.width - px(pad, s), .bottom = px(pad + search_height, s) };
    const list_top = search_rect.bottom + px(pad, s);
    const query = state.search.text();

    // The list first, so the search area covers what scrolls under it.
    var y = list_top - state.scroll;
    for ([_]bool{ false, true }) |wsl| {
        if (!sectionHasItems(state.items, wsl, query)) continue;
        y = paintSection(c, s, palette, fonts, if (wsl) profiles.data.sidebar.wsl else profiles.data.sidebar.local, y);
        // Groups in the order their first tab appears.
        for (state.items, 0..) |first, i| {
            if (first.wsl != wsl or !visible(first, query)) continue;
            if (seenGroupBefore(state.items[0..i], first.group, wsl, query)) continue;
            const holds_active = groupHolds(state.items, first.group, wsl, state.active);
            y = paintGroup(c, s, palette, fonts, first.group, holds_active, y);
            for (state.items) |item| {
                if (item.wsl != wsl or !visible(item, query) or !std.mem.eql(u8, item.group, first.group)) continue;
                y = paintItem(c, s, palette, fonts, state, item, list_top, spots, y);
            }
        }
    }
    const content_height = y + state.scroll - list_top;

    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = list_top }, palette.strip);
    state.search.paint(c, search_rect, s, .{
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

    return @max(0, content_height - (c.height - list_top));
}

fn visible(item: Item, query: []const u8) bool {
    return query.len == 0 or SearchField.matches(item.title, query) or SearchField.matches(item.group, query);
}

fn sectionHasItems(items: []const Item, wsl: bool, query: []const u8) bool {
    for (items) |item| {
        if (item.wsl == wsl and visible(item, query)) return true;
    }
    return false;
}

fn seenGroupBefore(earlier: []const Item, group: []const u8, wsl: bool, query: []const u8) bool {
    for (earlier) |item| {
        if (item.wsl == wsl and visible(item, query) and std.mem.eql(u8, item.group, group)) return true;
    }
    return false;
}

fn groupHolds(items: []const Item, group: []const u8, wsl: bool, tab: usize) bool {
    for (items) |item| {
        if (item.tab == tab and item.wsl == wsl and std.mem.eql(u8, item.group, group)) return true;
    }
    return false;
}

/// A section title followed by a rule to the right edge.
fn paintSection(c: Canvas, s: f32, palette: tab_strip.Palette, fonts: Fonts, title: []const u8, y: i32) i32 {
    const h = px(section_height, s);
    const left = px(pad + 6, s);
    c.text(.{ .left = left, .top = y, .right = c.width - px(pad, s), .bottom = y + h }, title, fonts.small, palette.text_dim, .left);
    const rule_left = left + c.textWidth(title, fonts.small) + px(10, s);
    const mid = y + @divTrunc(h, 2);
    c.fill(.{ .left = rule_left, .top = mid, .right = c.width - px(pad + 6, s), .bottom = mid + 1 }, palette.separator);
    return y + h;
}

fn paintGroup(c: Canvas, s: f32, palette: tab_strip.Palette, fonts: Fonts, name: []const u8, holds_active: bool, y: i32) i32 {
    const h = px(group_height, s);
    const left = px(pad + 6, s);
    const color = if (holds_active) palette.text else palette.text_dim;
    c.glyph(.{ .left = left, .top = y, .right = left + px(icon_size, s), .bottom = y + h }, icon_folder, fonts.icons, color);
    c.text(.{ .left = left + px(icon_size + 8, s), .top = y, .right = c.width - px(pad, s), .bottom = y + h }, name, if (holds_active) fonts.item_strong else fonts.item, color, .left);
    return y + h;
}

fn paintItem(c: Canvas, s: f32, palette: tab_strip.Palette, fonts: Fonts, state: State, item: Item, list_top: i32, spots: *Spots, y: i32) i32 {
    const h = px(item_height, s);
    const row: w32.RECT = .{ .left = px(pad, s), .top = y, .right = c.width - px(pad, s), .bottom = y + h };
    const active = item.tab == state.active;
    const hovered = state.hover.eql(.{ .tab = item.tab }) or state.hover.eql(.{ .close = item.tab });
    if (active) {
        c.fillRounded(row, px(corner, s), palette.active_tab);
    } else if (hovered) {
        c.fillRounded(row, px(corner, s), palette.hover);
    }

    const icon_left = row.left + px(item_indent, s);
    const size = px(icon_size, s);
    if (item.icon) |icon| {
        const top = y + @divTrunc(h - size, 2);
        c.sync();
        _ = w32.DrawIconEx(c.hdc, icon_left, top, icon, size, size, 0, null, w32.DI_NORMAL);
    }
    const side: w32.RECT = .{ .left = row.right - px(side_column, s), .top = y, .right = row.right - px(4, s), .bottom = y + h };
    const title_color = if (active or hovered) palette.text else palette.text_dim;
    c.text(.{ .left = icon_left + size + px(10, s), .top = y, .right = side.left - px(4, s), .bottom = y + h }, item.title, fonts.item, title_color, .left);

    // The right column shows, in order of priority: close on hover, the
    // bell dot, or how long ago the tab opened.
    const button = px(24, s);
    const close: w32.RECT = .{ .left = side.right - button, .top = y + @divTrunc(h - button, 2), .right = side.right, .bottom = y + @divTrunc(h - button, 2) + button };
    if (hovered) {
        if (state.hover.eql(.{ .close = item.tab })) c.fillRounded(close, @divTrunc(button, 2), palette.hover.mix(palette.contrast, 0.1));
        c.glyph(close, icon_close, fonts.icons_small, palette.text);
    } else if (item.attention) {
        const d = px(dot_size, s);
        const dot: w32.RECT = .{ .left = side.right - px(10, s) - d, .top = y + @divTrunc(h - d, 2), .right = side.right - px(10, s), .bottom = y + @divTrunc(h - d, 2) + d };
        c.fillRounded(dot, @divTrunc(d, 2), attention_red);
    } else {
        var buf: [8]u8 = undefined;
        c.text(side, age(&buf, item.age_ms), fonts.small, palette.text_dim, .right);
    }
    spots.add(clipTop(row, list_top), .{ .tab = item.tab });
    // Added after the row so it wins the hit test.
    if (hovered) spots.add(clipTop(close, list_top), .{ .close = item.tab });
    return y + h;
}

/// Rows that scrolled under the search box can't be clicked there.
fn clipTop(rect: w32.RECT, top: i32) w32.RECT {
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
