//! The strip at the top of a Sharp window: the tabs, the new-tab and
//! settings buttons and, when the strip replaces the Windows title bar,
//! the minimize, maximize and close buttons. Hit-testing and painting
//! share one Layout, so a click always lands on what was drawn.
//!
//! Tabs behave like Chrome's: they share the width equally, shrink as
//! more open, fade their title instead of hiding it, and only inactive
//! tabs wide enough keep a close button.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
pub const Rgb = canvas_mod.Rgb;

/// What sits under a point of the strip.
pub const Part = union(enum) {
    /// Outside the strip.
    none,
    /// Empty strip. Dragging it moves the window.
    caption,
    tab: usize,
    tab_close: usize,
    new_tab,
    settings,
    minimize,
    maximize,
    close,

    pub fn eql(a: Part, b: Part) bool {
        return std.meta.eql(a, b);
    }

    /// Caption buttons are non-client parts: their mouse messages arrive as
    /// WM_NC* messages, everything else as client messages.
    pub fn isCaptionButton(self: Part) bool {
        return switch (self) {
            .minimize, .maximize, .close => true,
            else => false,
        };
    }
};

/// Sizes in pixels at 96 DPI. Tab shape and close-button rule follow
/// Chromium's tab_style.cc and tab.cc; caption buttons follow Windows 11.
const strip_height = 40.0;
const tab_height = 34.0;
const tab_top_corner = 8.0;
/// Radius of the curves joining the active tab to the terminal below.
const tab_foot = 8.0;
const tab_max_width = 240.0;
/// Below this tabs overflow instead of shrinking; a few letters still show.
const tab_min_width = 24.0;
const tab_text_pad = 12.0;
/// Chrome hides an inactive tab's close button below this content width.
const close_min_content_width = 68.0;
const tab_close_size = 24.0;
const tab_close_pad = 6.0;
const title_fade = 24.0;
const separator_width = 2.0;
const separator_height = 16.0;
const hover_inset = 3.0;
const round_button_size = 28.0;
const round_button_gap = 4.0;
const caption_button_width = 46.0;
/// Space kept free between the buttons and the caption buttons so the
/// window can always be dragged, however many tabs are open.
const drag_space = 40.0;
const edge_margin = 8.0;

pub const Layout = struct {
    scale: f32,
    /// Client width of the window.
    width: i32,
    tab_count: usize,
    active: usize,
    show_tabs: bool,
    /// True when the strip replaces the Windows title bar.
    caption_buttons: bool,
    /// Width held while tabs are closed with the mouse; see Window.
    frozen_tab_width: ?i32 = null,

    pub fn height(self: Layout) i32 {
        if (!self.show_tabs and !self.caption_buttons) return 0;
        return self.px(strip_height);
    }

    fn px(self: Layout, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }

    fn tabsLeft(self: Layout) i32 {
        return self.px(edge_margin);
    }

    /// The right edge that tabs and buttons may not cross.
    fn limit(self: Layout) i32 {
        const buttons: i32 = @intCast(self.rightButtons().len);
        const gap = if (self.caption_buttons) self.px(drag_space) else self.px(edge_margin);
        return self.width - buttons * self.px(caption_button_width) - gap;
    }

    /// The buttons at the right end of the strip, left to right. Settings
    /// sits beside minimize; without a caption it is alone.
    pub fn rightButtons(self: Layout) []const Part {
        return if (self.caption_buttons)
            &.{ .settings, .minimize, .maximize, .close }
        else
            &.{.settings};
    }

    pub fn tabWidth(self: Layout) i32 {
        if (self.tab_count == 0) return 0;
        const n: i32 = @intCast(self.tab_count);
        const buttons = self.px(round_button_gap + round_button_size);
        const available = self.limit() - self.tabsLeft() - buttons;
        if (self.frozen_tab_width) |w| {
            if (w * n <= available) return w;
        }
        return std.math.clamp(@divTrunc(available, n), self.px(tab_min_width), self.px(tab_max_width));
    }

    pub fn tabRect(self: Layout, index: usize) w32.RECT {
        const w = self.tabWidth();
        const left = self.tabsLeft() + @as(i32, @intCast(index)) * w;
        const bottom = self.height();
        return .{ .left = left, .top = bottom - self.px(tab_height), .right = left + w, .bottom = bottom };
    }

    /// Tabs that overflow past the limit are neither drawn nor clickable.
    fn tabVisible(self: Layout, index: usize) bool {
        return self.tabRect(index).right <= self.limit();
    }

    pub fn showsClose(self: Layout, index: usize) bool {
        if (index == self.active) return true;
        const rect = self.tabRect(index);
        return rect.right - rect.left - 2 * self.px(tab_text_pad) >= self.px(close_min_content_width);
    }

    pub fn tabCloseRect(self: Layout, index: usize) w32.RECT {
        const tab = self.tabRect(index);
        const size = self.px(tab_close_size);
        const right = tab.right - self.px(tab_close_pad);
        const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
        return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
    }

    fn tabTextRect(self: Layout, index: usize) w32.RECT {
        const tab = self.tabRect(index);
        const pad = self.px(tab_text_pad);
        const right = if (self.showsClose(index))
            self.tabCloseRect(index).left - self.px(2)
        else
            tab.right - pad;
        // A tab too narrow for both paddings still shows what it can.
        const left = @min(tab.left + pad, tab.left + @divTrunc(tab.right - tab.left, 4));
        return .{ .left = left, .top = tab.top, .right = @max(left, right), .bottom = tab.bottom };
    }

    pub fn newTabRect(self: Layout) w32.RECT {
        const n: i32 = @intCast(self.tab_count);
        var tabs_right = self.tabsLeft() + n * self.tabWidth();
        tabs_right = @min(tabs_right, self.limit() - self.px(round_button_gap + round_button_size));
        const size = self.px(round_button_size);
        const left = tabs_right + self.px(round_button_gap);
        const top = self.height() - self.px(tab_height) + @divTrunc(self.px(tab_height) - size, 2);
        return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
    }

    /// One of rightButtons(), as wide as a Windows caption button.
    pub fn rightButtonRect(self: Layout, part: Part) w32.RECT {
        const buttons = self.rightButtons();
        const w = self.px(caption_button_width);
        const index = for (buttons, 0..) |b, i| {
            if (b.eql(part)) break i;
        } else unreachable;
        const from_right: i32 = @intCast(buttons.len - index);
        const left = self.width - from_right * w;
        return .{ .left = left, .top = 0, .right = left + w, .bottom = self.height() };
    }

    pub fn hitTest(self: Layout, x: i32, y: i32) Part {
        if (y < 0 or y >= self.height() or x < 0 or x >= self.width) return .none;
        for (self.rightButtons()) |part| {
            if (contains(self.rightButtonRect(part), x, y)) return part;
        }
        if (self.show_tabs) {
            for (0..self.tab_count) |i| {
                if (!self.tabVisible(i) or !contains(self.tabRect(i), x, y)) continue;
                if (self.showsClose(i) and contains(self.tabCloseRect(i), x, y)) return .{ .tab_close = i };
                return .{ .tab = i };
            }
            if (contains(self.newTabRect(), x, y)) return .new_tab;
        }
        return .caption;
    }

    /// The slot a dragged tab lands in when the pointer is at `x`.
    pub fn dropIndex(self: Layout, x: i32) usize {
        if (self.tab_count == 0) return 0;
        const w = @max(1, self.tabWidth());
        const slot = @divFloor(x - self.tabsLeft(), w);
        return @intCast(std.math.clamp(slot, 0, @as(i32, @intCast(self.tab_count - 1))));
    }
};

fn contains(rect: w32.RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

/// Strip colors derived from the terminal's own colors, so every theme
/// gets a matching title bar and the active tab blends into the terminal.
pub const Palette = struct {
    strip: Rgb,
    active_tab: Rgb,
    hover: Rgb,
    pressed: Rgb,
    separator: Rgb,
    text: Rgb,
    text_dim: Rgb,
    contrast: Rgb,

    /// Windows 11's close-button red.
    const close_hover: Rgb = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C };
    const close_pressed: Rgb = .{ .r = 0xB2, .g = 0x27, .b = 0x1A };

    pub fn fromTerminal(background: Rgb, foreground: Rgb) Palette {
        const dark = background.isDark();
        const contrast = if (dark) Rgb.white else Rgb.black;
        const strip = background.mix(Rgb.black, if (dark) 0.3 else 0.07);
        return .{
            .strip = strip,
            .active_tab = background,
            .hover = strip.mix(contrast, 0.08),
            .pressed = strip.mix(contrast, 0.05),
            .separator = strip.mix(contrast, 0.18),
            .text = foreground,
            .text_dim = foreground.mix(strip, 0.35),
            .contrast = contrast,
        };
    }
};

/// Segoe Fluent Icons code points (the same in Segoe MDL2 Assets).
const Glyph = enum(u16) {
    minimize = 0xE921,
    maximize = 0xE922,
    restore = 0xE923,
    close = 0xE8BB,
    add = 0xE710,
    settings = 0xE713,
};

pub const Fonts = struct {
    title: ?*anyopaque = null,
    icons: ?*anyopaque = null,
    icons_small: ?*anyopaque = null,
    icons_large: ?*anyopaque = null,

    /// `hdc` is only used to check which icon font Windows actually picked.
    pub fn init(hdc: w32.HDC, scale: f32) Fonts {
        const icon_face = canvas_mod.iconFace(hdc);
        return .{
            .title = canvas_mod.createFont(12, scale, canvas_mod.segoe_ui, w32.FW_NORMAL, .cleartype),
            .icons = canvas_mod.createFont(10, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_small = canvas_mod.createFont(8, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_large = canvas_mod.createFont(12, scale, icon_face, w32.FW_NORMAL, .grayscale),
        };
    }

    pub fn deinit(self: *Fonts) void {
        inline for (.{ &self.title, &self.icons, &self.icons_small, &self.icons_large }) |font| {
            if (font.*) |f| _ = w32.DeleteObject(f);
            font.* = null;
        }
    }
};

/// Pointer and window state that changes how the strip looks.
pub const View = struct {
    hover: Part = .none,
    pressed: Part = .none,
    window_active: bool = true,
    maximized: bool = false,
};

pub const Titles = struct {
    text: []const [256]u16,
    lens: []const u16,
};

/// Paint the whole strip. Shapes go straight into the pixels and text
/// through GDI, so the order below is also the stacking order.
pub fn paint(canvas: Canvas, layout: Layout, palette: Palette, fonts: Fonts, titles: Titles, view: View) void {
    canvas.fill(.{ .left = 0, .top = 0, .right = layout.width, .bottom = layout.height() }, palette.strip);
    _ = w32.SetBkMode(canvas.hdc, w32.TRANSPARENT);

    if (layout.show_tabs) {
        for (0..layout.tab_count) |i| {
            if (!layout.tabVisible(i)) break;
            paintTab(canvas, layout, palette, fonts, titles, view, i);
        }
        paintRoundButton(canvas, layout.newTabRect(), .add, view.hover.eql(.new_tab), palette, fonts);
    }

    for (layout.rightButtons()) |part| {
        const rect = layout.rightButtonRect(part);
        const hovered = view.hover.eql(part);
        // The settings button stays lit while its menu is open.
        const menu_open = part == .settings and view.pressed.eql(.settings);
        const pressed = (hovered or menu_open) and view.pressed.eql(part);
        const is_close = part == .close;
        canvas.sync();
        if (hovered or menu_open) {
            const color = if (is_close)
                (if (pressed) Palette.close_pressed else Palette.close_hover)
            else if (pressed) palette.pressed else palette.hover;
            canvas.fill(rect, color);
        }
        const glyph: Glyph = switch (part) {
            .settings => .settings,
            .minimize => .minimize,
            .maximize => if (view.maximized) .restore else .maximize,
            else => .close,
        };
        const color = if (hovered and is_close)
            Rgb.white
        else if (view.window_active or hovered)
            palette.text
        else
            palette.text_dim;
        // The gear reads smaller than the caption glyphs at the same size.
        canvas.glyph(rect, @backingInt(glyph), if (part == .settings) fonts.icons_large else fonts.icons, color);
    }
    canvas.sync();
}

fn paintTab(canvas: Canvas, layout: Layout, palette: Palette, fonts: Fonts, titles: Titles, view: View, i: usize) void {
    const rect = layout.tabRect(i);
    const active = i == layout.active;
    const hovered = view.hover.eql(.{ .tab = i }) or view.hover.eql(.{ .tab_close = i });
    canvas.sync();

    const background = if (active) palette.active_tab else if (hovered) palette.hover else palette.strip;
    if (active) {
        fillActiveTab(canvas, rect, layout.px(tab_top_corner), layout.px(tab_foot), palette.active_tab);
    } else if (hovered) {
        const inset = layout.px(hover_inset);
        canvas.fillRounded(.{ .left = rect.left + inset, .top = rect.top + inset, .right = rect.right - inset, .bottom = rect.bottom - inset }, layout.px(tab_top_corner), palette.hover);
    }

    // Separators only between two resting tabs, as in Chrome.
    const next = i + 1;
    const next_resting = next < layout.tab_count and next != layout.active and
        !view.hover.eql(.{ .tab = next }) and !view.hover.eql(.{ .tab_close = next });
    if (!active and !hovered and next_resting) {
        const w = @max(1, layout.px(separator_width));
        const h = layout.px(separator_height);
        const top = rect.top + @divTrunc(rect.bottom - rect.top - h, 2);
        canvas.fill(.{ .left = rect.right - @divTrunc(w, 2), .top = top, .right = rect.right - @divTrunc(w, 2) + w, .bottom = top + h }, palette.separator);
    }

    const text_color = if ((active or hovered) and view.window_active) palette.text else palette.text_dim;
    const text_rect = layout.tabTextRect(i);
    const len = titles.lens[i];
    if (len > 0 and text_rect.right > text_rect.left) {
        _ = w32.SelectObject(canvas.hdc, fonts.title);
        _ = w32.SetTextColor(canvas.hdc, text_color.ref());
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(canvas.hdc, &titles.text[i], len, &size);
        var r = text_rect;
        _ = w32.DrawTextW(canvas.hdc, &titles.text[i], len, &r, w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
        if (size.cx > text_rect.right - text_rect.left) {
            canvas.sync();
            canvas.fadeRight(text_rect, layout.px(title_fade), background);
        }
    }

    if (layout.showsClose(i)) {
        const close_rect = layout.tabCloseRect(i);
        if (view.hover.eql(.{ .tab_close = i })) {
            canvas.sync();
            canvas.fillRounded(close_rect, @divTrunc(close_rect.right - close_rect.left, 2), background.mix(palette.contrast, 0.12));
        }
        canvas.glyph(close_rect, @backingInt(Glyph.close), fonts.icons_small, text_color);
    }
}

fn paintRoundButton(canvas: Canvas, rect: w32.RECT, glyph: Glyph, hovered: bool, palette: Palette, fonts: Fonts) void {
    if (hovered) {
        canvas.sync();
        canvas.fillRounded(rect, @divTrunc(rect.right - rect.left, 2), palette.hover);
    }
    canvas.glyph(rect, @backingInt(glyph), fonts.icons_large, if (hovered) palette.text else palette.text_dim);
}

/// The active tab: rounded on top, and curving out at the bottom into the
/// terminal below, Chrome's signature shape.
fn fillActiveTab(canvas: Canvas, rect: w32.RECT, top: i32, foot: i32, color: Rgb) void {
    canvas.fill(.{ .left = rect.left + top, .top = rect.top, .right = rect.right - top, .bottom = rect.bottom }, color);
    canvas.fill(.{ .left = rect.left, .top = rect.top + top, .right = rect.left + top, .bottom = rect.bottom }, color);
    canvas.fill(.{ .left = rect.right - top, .top = rect.top + top, .right = rect.right, .bottom = rect.bottom }, color);
    canvas.corner(rect.left, rect.top, top, .{ 1, 1 }, .inside, color);
    canvas.corner(rect.right - top, rect.top, top, .{ 0, 1 }, .inside, color);
    canvas.corner(rect.left - foot, rect.bottom - foot, foot, .{ 0, 0 }, .outside, color);
    canvas.corner(rect.right, rect.bottom - foot, foot, .{ 1, 0 }, .outside, color);
}
