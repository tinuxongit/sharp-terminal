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
    /// The arrow beside "+" that opens the shell profile menu.
    new_tab_menu,
    /// Shown once an update is downloaded: restarts into it.
    update,
    /// The globe that shows or hides the browser panel.
    browser,
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
const new_tab_height = 28.0;
const new_tab_width = 32.0;
const new_tab_menu_width = 22.0;
const new_tab_gap = 4.0;
const tab_icon_size = 16.0;
const tab_icon_gap = 8.0;
const caption_button_width = 46.0;
/// Space kept free between the buttons and the caption buttons so the
/// window can always be dragged, however many tabs are open.
const drag_space = 40.0;
const edge_margin = 8.0;
/// The administrator shield before the tabs.
const shield_width = 28.0;

/// How tabs look; the `window-tab-style` setting.
pub const Style = enum {
    /// Rounded tabs whose active one flows into the terminal.
    chrome,
    /// Flat tabs with rounded tops and no separators.
    windows_terminal,
};

pub const Layout = struct {
    scale: f32,
    style: Style = .chrome,
    /// Client width of the window.
    width: i32,
    tab_count: usize,
    active: usize,
    show_tabs: bool,
    /// True when the strip replaces the Windows title bar.
    caption_buttons: bool,
    /// Width held while tabs are closed with the mouse; see Window.
    frozen_tab_width: ?i32 = null,
    /// Tabs live in the sidebar: the strip shows only the active title, and
    /// new tabs open from the sidebar's folders.
    sidebar: bool = false,
    /// Settings > AI > Tools > Browser is on, so the globe shows.
    browser: bool = false,
    /// An update is ready to install.
    update: bool = false,
    /// Sharp runs as administrator: a shield leads the tabs.
    admin: bool = false,

    pub fn height(self: Layout) i32 {
        if (!self.show_tabs and !self.caption_buttons and !self.sidebar) return 0;
        return self.px(strip_height);
    }

    fn px(self: Layout, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }

    fn tabsLeft(self: Layout) i32 {
        return self.px(edge_margin) + if (self.admin) self.px(shield_width) else 0;
    }

    fn shieldRect(self: Layout) w32.RECT {
        const left = self.px(edge_margin);
        return .{ .left = left, .top = 0, .right = left + self.px(shield_width), .bottom = self.height() };
    }

    /// The right edge that tabs and buttons may not cross.
    fn limit(self: Layout) i32 {
        const buttons: i32 = @intCast(self.rightButtons().len());
        const gap = if (self.caption_buttons) self.px(drag_space) else self.px(edge_margin);
        return self.width - buttons * self.px(caption_button_width) - gap;
    }

    /// The buttons at the right end of the strip, left to right: the
    /// update button and the globe when they show, then settings beside
    /// minimize.
    pub fn rightButtons(self: Layout) RightButtons {
        var buttons: RightButtons = .{};
        if (self.update) buttons.add(.update);
        if (self.browser) buttons.add(.browser);
        buttons.add(.settings);
        if (self.caption_buttons) {
            buttons.add(.minimize);
            buttons.add(.maximize);
            buttons.add(.close);
        }
        return buttons;
    }

    pub const RightButtons = struct {
        items: [6]Part = undefined,
        count: usize = 0,

        fn add(self: *RightButtons, part: Part) void {
            self.items[self.count] = part;
            self.count += 1;
        }

        pub fn len(self: *const RightButtons) usize {
            return self.count;
        }

        pub fn slice(self: *const RightButtons) []const Part {
            return self.items[0..self.count];
        }
    };

    pub fn tabWidth(self: Layout) i32 {
        if (self.tab_count == 0) return 0;
        const n: i32 = @intCast(self.tab_count);
        const buttons = self.px(new_tab_gap + new_tab_width + new_tab_menu_width);
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

    /// Where the shell's icon sits, at the start of the tab.
    fn tabIconRect(self: Layout, index: usize) w32.RECT {
        const tab = self.tabRect(index);
        const size = self.px(tab_icon_size);
        // A tab too narrow for the padding still shows what it can.
        const left = @min(tab.left + self.px(tab_text_pad), tab.left + @divTrunc(tab.right - tab.left, 6));
        const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
        return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
    }

    fn tabTextRect(self: Layout, index: usize) w32.RECT {
        const tab = self.tabRect(index);
        const right = if (self.showsClose(index))
            self.tabCloseRect(index).left - self.px(2)
        else
            tab.right - self.px(tab_text_pad);
        const left = self.tabIconRect(index).right + self.px(tab_icon_gap);
        return .{ .left = left, .top = tab.top, .right = @max(left, right), .bottom = tab.bottom };
    }

    /// "+" and the profile arrow form one split button after the last tab.
    fn newTabGroupRect(self: Layout) w32.RECT {
        const n: i32 = @intCast(self.tab_count);
        const width = self.px(new_tab_width + new_tab_menu_width);
        var tabs_right = self.tabsLeft() + n * self.tabWidth();
        tabs_right = @min(tabs_right, self.limit() - self.px(new_tab_gap) - width);
        const height_ = self.px(new_tab_height);
        const left = tabs_right + self.px(new_tab_gap);
        const top = self.height() - self.px(tab_height) + @divTrunc(self.px(tab_height) - height_, 2);
        return .{ .left = left, .top = top, .right = left + width, .bottom = top + height_ };
    }

    pub fn newTabRect(self: Layout) w32.RECT {
        var r = self.newTabGroupRect();
        r.right = r.left + self.px(new_tab_width);
        return r;
    }

    pub fn newTabMenuRect(self: Layout) w32.RECT {
        var r = self.newTabGroupRect();
        r.left = r.right - self.px(new_tab_menu_width);
        return r;
    }

    /// One of rightButtons(), as wide as a Windows caption button.
    pub fn rightButtonRect(self: Layout, part: Part) w32.RECT {
        const buttons = self.rightButtons();
        const w = self.px(caption_button_width);
        const index = for (buttons.slice(), 0..) |b, i| {
            if (b.eql(part)) break i;
        } else unreachable;
        const from_right: i32 = @intCast(buttons.len() - index);
        const left = self.width - from_right * w;
        return .{ .left = left, .top = 0, .right = left + w, .bottom = self.height() };
    }

    pub fn hitTest(self: Layout, x: i32, y: i32) Part {
        if (y < 0 or y >= self.height() or x < 0 or x >= self.width) return .none;
        const buttons = self.rightButtons();
        for (buttons.slice()) |part| {
            if (contains(self.rightButtonRect(part), x, y)) return part;
        }
        if (self.show_tabs) {
            for (0..self.tab_count) |i| {
                if (!self.tabVisible(i) or !contains(self.tabRect(i), x, y)) continue;
                if (self.showsClose(i) and contains(self.tabCloseRect(i), x, y)) return .{ .tab_close = i };
                return .{ .tab = i };
            }
        }
        if (self.show_tabs) {
            if (contains(self.newTabRect(), x, y)) return .new_tab;
            if (contains(self.newTabMenuRect(), x, y)) return .new_tab_menu;
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

    /// The update button's green, which stands out on any theme.
    const update: Rgb = .{ .r = 0x3F, .g = 0xB9, .b = 0x50 };

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
    chevron_down = 0xE70D,
    settings = 0xE713,
    globe = 0xE774,
    /// Segoe's "update restore": an arrow around, as Windows Update shows.
    update = 0xE777,
    shield = 0xEA18,
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
    /// The globe stays lit while the browser panel shows.
    browser_open: bool = false,
};

pub const Titles = struct {
    text: []const [256]u16,
    lens: []const u16,
    /// Each tab's shell icon, drawn at tab_icon_size.
    icons: []const ?w32.HICON,
};

/// Paint the whole strip. Shapes go straight into the pixels and text
/// through GDI, so the order below is also the stacking order.
pub fn paint(canvas: Canvas, layout: Layout, palette: Palette, fonts: Fonts, titles: Titles, view: View) void {
    canvas.fill(.{ .left = 0, .top = 0, .right = layout.width, .bottom = layout.height() }, palette.strip);
    _ = w32.SetBkMode(canvas.hdc, w32.TRANSPARENT);
    if (layout.admin) canvas.glyph(layout.shieldRect(), @backingInt(Glyph.shield), fonts.icons, palette.text_dim);

    if (layout.show_tabs) {
        for (0..layout.tab_count) |i| {
            if (!layout.tabVisible(i)) break;
            paintTab(canvas, layout, palette, fonts, titles, view, i);
        }
        paintNewTabButton(canvas, layout, palette, fonts, view);
    } else if (layout.sidebar) {
        // With tabs in the sidebar, the strip names the active one.
        if (layout.active < titles.lens.len) {
            const title: w32.RECT = .{ .left = layout.tabsLeft() + layout.px(10), .top = 0, .right = layout.limit(), .bottom = layout.height() };
            canvas.textWide(title, titles.text[layout.active][0..titles.lens[layout.active]], fonts.title, if (view.window_active) palette.text else palette.text_dim, .left, w32.DT_END_ELLIPSIS);
        }
    }

    const buttons = layout.rightButtons();
    for (buttons.slice()) |part| {
        const rect = layout.rightButtonRect(part);
        const hovered = view.hover.eql(part);
        // The settings button stays lit while its panel is open, and the
        // globe while the browser shows.
        const menu_open = (part == .settings and view.pressed.eql(.settings)) or
            (part == .browser and view.browser_open);
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
            .browser => .globe,
            .update => .update,
            .minimize => .minimize,
            .maximize => if (view.maximized) .restore else .maximize,
            else => .close,
        };
        const color = if (hovered and is_close)
            Rgb.white
        else if (part == .update)
            Palette.update
        else if (view.window_active or hovered)
            palette.text
        else
            palette.text_dim;
        // The gear reads smaller than the caption glyphs at the same size.
        const large = part == .settings or part == .browser or part == .update;
        canvas.glyph(rect, @backingInt(glyph), if (large) fonts.icons_large else fonts.icons, color);
    }
    canvas.sync();
}

fn paintTab(canvas: Canvas, layout: Layout, palette: Palette, fonts: Fonts, titles: Titles, view: View, i: usize) void {
    const rect = layout.tabRect(i);
    const active = i == layout.active;
    const hovered = view.hover.eql(.{ .tab = i }) or view.hover.eql(.{ .tab_close = i });
    canvas.sync();

    const background = if (active) palette.active_tab else if (hovered) palette.hover else palette.strip;
    const foot = if (layout.style == .chrome) layout.px(tab_foot) else 0;
    if (active) {
        fillActiveTab(canvas, rect, layout.px(tab_top_corner), foot, palette.active_tab);
    } else if (hovered and layout.style == .windows_terminal) {
        fillActiveTab(canvas, rect, layout.px(tab_top_corner), 0, palette.hover);
    } else if (hovered) {
        const inset = layout.px(hover_inset);
        canvas.fillRounded(.{ .left = rect.left + inset, .top = rect.top + inset, .right = rect.right - inset, .bottom = rect.bottom - inset }, layout.px(tab_top_corner), palette.hover);
    }

    // Separators only between two resting tabs, as in Chrome.
    const next = i + 1;
    const next_resting = next < layout.tab_count and next != layout.active and
        !view.hover.eql(.{ .tab = next }) and !view.hover.eql(.{ .tab_close = next });
    if (layout.style == .chrome and !active and !hovered and next_resting) {
        const w = @max(1, layout.px(separator_width));
        const h = layout.px(separator_height);
        const top = rect.top + @divTrunc(rect.bottom - rect.top - h, 2);
        canvas.fill(.{ .left = rect.right - @divTrunc(w, 2), .top = top, .right = rect.right - @divTrunc(w, 2) + w, .bottom = top + h }, palette.separator);
    }

    const text_color = if ((active or hovered) and view.window_active) palette.text else palette.text_dim;
    if (titles.icons[i]) |icon| {
        const r = layout.tabIconRect(i);
        if (r.right <= rect.right) _ = w32.DrawIconEx(canvas.hdc, r.left, r.top, icon, r.right - r.left, r.bottom - r.top, 0, null, w32.DI_NORMAL);
    }

    const text_rect = layout.tabTextRect(i);
    const len = titles.lens[i];
    if (len > 0 and text_rect.right > text_rect.left) {
        // Chrome fades a title that doesn't fit; Windows Terminal cuts it
        // with an ellipsis.
        const fade = layout.style == .chrome;
        canvas.textWide(text_rect, titles.text[i][0..len], fonts.title, text_color, .left, if (fade) 0 else w32.DT_END_ELLIPSIS);
        if (fade) {
            _ = w32.SelectObject(canvas.hdc, fonts.title);
            var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
            _ = w32.GetTextExtentPoint32W(canvas.hdc, &titles.text[i], len, &size);
            if (size.cx > text_rect.right - text_rect.left) {
                canvas.sync();
                canvas.fadeRight(text_rect, layout.px(title_fade), background);
            }
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

fn paintNewTabButton(canvas: Canvas, layout: Layout, palette: Palette, fonts: Fonts, view: View) void {
    const plus = layout.newTabRect();
    const arrow = layout.newTabMenuRect();
    const on_plus = view.hover.eql(.new_tab);
    const on_arrow = view.hover.eql(.new_tab_menu) or view.pressed.eql(.new_tab_menu);
    const corner = layout.px(6);
    if (on_plus or on_arrow) {
        canvas.sync();
        canvas.fillRounded(.{ .left = plus.left, .top = plus.top, .right = arrow.right, .bottom = plus.bottom }, corner, palette.hover);
        canvas.fillRounded(if (on_plus) plus else arrow, corner, palette.hover.mix(palette.contrast, 0.07));
        canvas.fill(.{ .left = arrow.left, .top = plus.top + layout.px(6), .right = arrow.left + 1, .bottom = plus.bottom - layout.px(6) }, palette.separator);
    }
    canvas.glyph(plus, @backingInt(Glyph.add), fonts.icons_large, if (on_plus) palette.text else palette.text_dim);
    canvas.glyph(arrow, @backingInt(Glyph.chevron_down), fonts.icons_small, if (on_arrow) palette.text else palette.text_dim);
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
