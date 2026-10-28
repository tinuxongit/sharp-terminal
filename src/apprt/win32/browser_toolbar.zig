//! The browser panel's toolbar: back, forward and reload, and the address
//! box. Hit-testing and painting share one Layout, so a click always
//! lands on what was drawn.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const SearchField = @import("SearchField.zig");

/// Sizes in pixels at 96 DPI.
const toolbar_height = 40.0;
const button_width = 32.0;
const button_height = 28.0;
const gap = 6.0;

const glyph_back = 0xE72B;
const glyph_forward = 0xE72A;
const glyph_reload = 0xE72C;
const glyph_globe = 0xE774;

pub const Target = enum { none, back, forward, reload, address };

pub const Layout = struct {
    scale: f32,
    /// The panel's client width.
    width: i32,

    pub fn px(self: Layout, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }

    pub fn height(self: Layout) i32 {
        return self.px(toolbar_height);
    }

    pub fn rect(self: Layout, target: Target) w32.RECT {
        const top = @divTrunc(self.height() - self.px(button_height), 2);
        const bottom = top + self.px(button_height);
        const slot: i32 = switch (target) {
            .back => 0,
            .forward => 1,
            .reload => 2,
            .address => {
                const left = self.px(gap) + 3 * self.px(button_width) + self.px(gap);
                return .{ .left = left, .top = top, .right = @max(left, self.width - self.px(gap)), .bottom = bottom };
            },
            .none => return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
        const left = self.px(gap) + slot * self.px(button_width);
        return .{ .left = left, .top = top, .right = left + self.px(button_width), .bottom = bottom };
    }

    pub fn hit(self: Layout, x: i32, y: i32) Target {
        for ([_]Target{ .back, .forward, .reload, .address }) |t| {
            const r = self.rect(t);
            if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return t;
        }
        return .none;
    }
};

/// What the toolbar shows.
pub const View = struct {
    palette: tab_strip.Palette,
    fonts: tab_strip.Fonts,
    address: *const SearchField,
    placeholder: []const u8,
    hover: Target,
    pressed: Target,
    /// Which buttons can be used now; the rest are dimmed.
    can_back: bool,
    can_forward: bool,
    ready: bool,

    pub fn enabled(self: View, target: Target) bool {
        return switch (target) {
            .back => self.can_back,
            .forward => self.can_forward,
            .reload, .address => self.ready,
            .none => false,
        };
    }
};

pub fn paint(c: canvas_mod.Canvas, layout: Layout, view: View) void {
    const pal = view.palette;
    c.fill(.{ .left = 0, .top = 0, .right = layout.width, .bottom = layout.height() }, pal.strip);
    _ = w32.SetBkMode(c.hdc, w32.TRANSPARENT);
    for ([_]struct { Target, u16 }{ .{ .back, glyph_back }, .{ .forward, glyph_forward }, .{ .reload, glyph_reload } }) |button| {
        const target, const glyph = button;
        const rect = layout.rect(target);
        const on = view.enabled(target);
        c.sync();
        if (on and view.hover == target) {
            c.fillRounded(rect, layout.px(4), if (view.pressed == target) pal.pressed else pal.hover);
        }
        c.glyph(rect, glyph, view.fonts.icons, if (on) pal.text else pal.text_dim.mix(pal.strip, 0.5));
    }
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
