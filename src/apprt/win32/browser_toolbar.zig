//! The browser panel's toolbar: a row of tabs with "+", then back,
//! forward, reload and the address box. Hit-testing and painting share
//! one Layout, so a click always lands on what was drawn.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const SearchField = @import("SearchField.zig");

/// Sizes in pixels at 96 DPI.
const tabs_height = 34.0;
const tab_height = 28.0;
const tab_max_width = 200.0;
const tab_min_width = 48.0;
const tab_close_size = 20.0;
const nav_height = 40.0;
const button_width = 32.0;
const button_height = 28.0;
const gap = 6.0;
/// The panel's left edge, which resizes it.
const grip_width = 5.0;

const glyph_back = 0xE72B;
const glyph_forward = 0xE72A;
const glyph_reload = 0xE72C;
const glyph_globe = 0xE774;
const glyph_add = 0xE710;
const glyph_close = 0xE8BB;
const glyph_stop = 0xE711;
const glyph_desktop = 0xE7F4;
const glyph_phone = 0xE8EA;
const glyph_outside = 0xE8A7;
const glyph_expand = 0xE740;
const glyph_shrink = 0xE73F;

pub const Target = union(enum) {
    none,
    grip,
    tab: usize,
    tab_close: usize,
    new_tab,
    back,
    forward,
    reload,
    address,
    page_size,
    outside,
    expand,
    dialog_ok,
    dialog_cancel,
    dialog_field,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Layout = struct {
    scale: f32,
    /// The panel's client width.
    width: i32,
    tab_count: usize,

    pub fn px(self: Layout, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }

    pub fn height(self: Layout) i32 {
        return self.px(tabs_height) + self.px(nav_height);
    }

    pub fn gripWidth(self: Layout) i32 {
        return @max(1, self.px(grip_width));
    }

    fn tabsLeft(self: Layout) i32 {
        return self.gripWidth() + self.px(gap);
    }

    fn tabWidth(self: Layout) i32 {
        if (self.tab_count == 0) return 0;
        const n: i32 = @intCast(self.tab_count);
        const available = self.width - self.tabsLeft() - self.px(gap) - self.px(button_width);
        return std.math.clamp(@divTrunc(available, n), self.px(tab_min_width), self.px(tab_max_width));
    }

    /// Tabs past the right edge are left out; they are still reachable
    /// with Ctrl+Tab.
    pub fn tabVisible(self: Layout, i: usize) bool {
        return self.tabRect(i).right <= self.width - self.px(button_width) - self.px(gap);
    }

    pub fn tabRect(self: Layout, i: usize) w32.RECT {
        const top = @divTrunc(self.px(tabs_height) - self.px(tab_height), 2) + self.px(2);
        const left = self.tabsLeft() + @as(i32, @intCast(i)) * self.tabWidth();
        return .{ .left = left, .top = top, .right = left + self.tabWidth() - self.px(2), .bottom = top + self.px(tab_height) };
    }

    pub fn tabCloseRect(self: Layout, i: usize) w32.RECT {
        const tab = self.tabRect(i);
        const size = self.px(tab_close_size);
        const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
        return .{ .left = tab.right - self.px(4) - size, .top = top, .right = tab.right - self.px(4), .bottom = top + size };
    }

    pub fn rect(self: Layout, target: Target) w32.RECT {
        const nav_top = self.px(tabs_height);
        const top = nav_top + @divTrunc(self.px(nav_height) - self.px(button_height), 2);
        const bottom = top + self.px(button_height);
        const slot: i32 = switch (target) {
            .back => 0,
            .forward => 1,
            .reload => 2,
            .address => {
                const left = self.gripWidth() + self.px(gap) + 3 * self.px(button_width) + self.px(gap);
                const right = self.width - self.px(gap) - 3 * self.px(button_width) - self.px(gap);
                return .{ .left = left, .top = top, .right = @max(left, right), .bottom = bottom };
            },
            .page_size, .outside, .expand => {
                const from_right: i32 = switch (target) {
                    .page_size => 3,
                    .outside => 2,
                    else => 1,
                };
                const left = self.width - self.px(gap) - from_right * self.px(button_width);
                return .{ .left = left, .top = top, .right = left + self.px(button_width), .bottom = bottom };
            },
            .new_tab => {
                var last: usize = 0;
                while (last < self.tab_count and self.tabVisible(last)) last += 1;
                const left = if (last == 0) self.tabsLeft() else self.tabRect(last - 1).right + self.px(4);
                const t = self.tabRect(0);
                return .{ .left = left, .top = t.top, .right = left + self.px(button_width), .bottom = t.bottom };
            },
            .tab => |i| return self.tabRect(i),
            .tab_close => |i| return self.tabCloseRect(i),
            .grip => return .{ .left = 0, .top = 0, .right = self.gripWidth(), .bottom = std.math.maxInt(i32) },
            .none, .dialog_ok, .dialog_cancel, .dialog_field => return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
        const left = self.gripWidth() + self.px(gap) + slot * self.px(button_width);
        return .{ .left = left, .top = top, .right = left + self.px(button_width), .bottom = bottom };
    }

    pub fn hit(self: Layout, x: i32, y: i32) Target {
        if (x < self.gripWidth()) return .grip;
        for (0..self.tab_count) |i| {
            if (!self.tabVisible(i)) break;
            if (contains(self.tabCloseRect(i), x, y)) return .{ .tab_close = i };
            if (contains(self.tabRect(i), x, y)) return .{ .tab = i };
        }
        for ([_]Target{ .new_tab, .back, .forward, .reload, .address, .page_size, .outside, .expand }) |t| {
            if (contains(self.rect(t), x, y)) return t;
        }
        return .none;
    }
};

fn contains(r: w32.RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

/// What the toolbar shows.
pub const View = struct {
    palette: tab_strip.Palette,
    fonts: tab_strip.Fonts,
    titles: []const []const u8,
    active: usize,
    address: *const SearchField,
    placeholder: []const u8,
    hover: Target,
    pressed: Target,
    /// Which buttons can be used now; the rest are dimmed.
    can_back: bool,
    can_forward: bool,
    ready: bool,
    can_add: bool,
    loading: bool,
    mobile: bool,
    expanded: bool,

    pub fn enabled(self: View, target: Target) bool {
        return switch (target) {
            .back => self.can_back,
            .forward => self.can_forward,
            .reload, .address, .page_size, .outside => self.ready,
            .expand => true,
            .new_tab => self.can_add,
            .tab, .tab_close, .grip, .dialog_ok, .dialog_cancel, .dialog_field => true,
            .none => false,
        };
    }
};

pub fn paint(c: canvas_mod.Canvas, layout: Layout, view: View) void {
    const pal = view.palette;
    c.fill(.{ .left = 0, .top = 0, .right = layout.width, .bottom = layout.height() }, pal.strip);
    // The edge beside the terminal, brighter while it can be dragged.
    c.fill(.{ .left = 0, .top = 0, .right = @max(1, layout.px(1)), .bottom = layout.height() }, if (view.hover == .grip) pal.text_dim else pal.separator);
    _ = w32.SetBkMode(c.hdc, w32.TRANSPARENT);

    for (view.titles, 0..) |title, i| {
        if (!layout.tabVisible(i)) break;
        const rect = layout.tabRect(i);
        const active = i == view.active;
        const hovered = view.hover.eql(.{ .tab = i }) or view.hover.eql(.{ .tab_close = i });
        c.sync();
        if (active or hovered) c.fillRounded(rect, layout.px(6), if (active) pal.active_tab else pal.hover);
        const shows_close = active or hovered;
        const text_right = if (shows_close) layout.tabCloseRect(i).left - layout.px(2) else rect.right - layout.px(8);
        c.text(.{ .left = rect.left + layout.px(10), .top = rect.top, .right = text_right, .bottom = rect.bottom }, title, view.fonts.title, if (active) pal.text else pal.text_dim, .left);
        if (shows_close) {
            const close = layout.tabCloseRect(i);
            c.sync();
            if (view.hover.eql(.{ .tab_close = i })) c.fillRounded(close, layout.px(4), pal.hover.mix(pal.contrast, 0.08));
            c.glyph(close, glyph_close, view.fonts.icons_small, pal.text_dim);
        }
    }
    paintButton(c, layout, view, .new_tab, glyph_add);
    paintButton(c, layout, view, .back, glyph_back);
    paintButton(c, layout, view, .forward, glyph_forward);
    paintButton(c, layout, view, .reload, if (view.loading) glyph_stop else glyph_reload);
    paintButton(c, layout, view, .page_size, if (view.mobile) glyph_phone else glyph_desktop);
    paintButton(c, layout, view, .outside, glyph_outside);
    paintButton(c, layout, view, .expand, if (view.expanded) glyph_shrink else glyph_expand);
    c.sync();
    view.address.paint(c, layout.rect(.address), layout.scale, .{
        .fill = pal.strip.mix(pal.contrast, 0.06),
        .hover = pal.hover,
        .focused = pal.hover.mix(pal.contrast, 0.05),
        .text = pal.text,
        .text_dim = pal.text_dim,
        .font = view.fonts.title,
        .icon_font = view.fonts.icons_small,
        .placeholder = view.placeholder,
        .icon = glyph_globe,
    }, view.hover == .address, true);
    c.sync();
}

fn paintButton(c: canvas_mod.Canvas, layout: Layout, view: View, target: Target, glyph: u16) void {
    const pal = view.palette;
    const rect = layout.rect(target);
    const on = view.enabled(target);
    c.sync();
    if (on and view.hover.eql(target)) {
        c.fillRounded(rect, layout.px(4), if (view.pressed.eql(target)) pal.pressed else pal.hover);
    }
    c.glyph(rect, glyph, if (target == .new_tab) view.fonts.icons_small else view.fonts.icons, if (on) pal.text else pal.text_dim.mix(pal.strip, 0.5));
}
