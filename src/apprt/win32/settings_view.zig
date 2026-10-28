//! Layout and painting of the settings panel. It draws one frame from the
//! panel's state and records the clickable spots it drew; input and
//! window handling live in SettingsPanel.zig.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const settings = @import("settings.zig");
const profiles_mod = @import("profiles.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

pub const Target = union(enum) {
    none,
    /// The dimmed terminal around the panel. Clicking it closes the panel.
    backdrop,
    close,
    restore,
    search,
    category: usize,
    control: settings.Ref,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Spots = struct {
    items: [160]Spot = undefined,
    len: usize = 0,

    pub const Spot = struct { rect: w32.RECT, target: Target };

    fn add(self: *Spots, rect: w32.RECT, target: Target) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = .{ .rect = rect, .target = target };
        self.len += 1;
    }

    /// The topmost spot under a point: later spots were drawn on top.
    pub fn at(self: *const Spots, x: i32, y: i32) ?Spot {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const r = self.items[i].rect;
            if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return self.items[i];
        }
        return null;
    }
};

/// Panel colors derived from the terminal's, like the tab strip's, plus
/// the Windows accent color for switched-on toggles.
pub const Palette = struct {
    panel: Rgb,
    sidebar: Rgb,
    card: Rgb,
    border: Rgb,
    hover: Rgb,
    selected: Rgb,
    panel_hover: Rgb,
    control: Rgb,
    control_hover: Rgb,
    text: Rgb,
    text_dim: Rgb,
    accent: Rgb,
    dark: bool,

    pub fn fromTerminal(background: Rgb, foreground: Rgb, accent: Rgb) Palette {
        const dark = background.isDark();
        const contrast = if (dark) Rgb.white else Rgb.black;
        const panel = background.mix(Rgb.black, if (dark) 0.15 else 0.0);
        const sidebar = background.mix(Rgb.black, if (dark) 0.3 else 0.04);
        return .{
            .panel = panel,
            .sidebar = sidebar,
            .card = panel.mix(contrast, 0.05),
            .border = panel.mix(contrast, 0.09),
            .hover = sidebar.mix(contrast, 0.06),
            .selected = sidebar.mix(contrast, 0.11),
            .panel_hover = panel.mix(contrast, 0.08),
            .control = panel.mix(contrast, 0.11),
            .control_hover = panel.mix(contrast, 0.16),
            .text = foreground,
            .text_dim = foreground.mix(panel, 0.45),
            .accent = accent,
            .dark = dark,
        };
    }
};

pub const Fonts = struct {
    body: ?*anyopaque = null,
    strong: ?*anyopaque = null,
    small: ?*anyopaque = null,
    heading: ?*anyopaque = null,
    crumb: ?*anyopaque = null,
    crumb_strong: ?*anyopaque = null,
    icons: ?*anyopaque = null,
    icons_small: ?*anyopaque = null,

    pub fn init(hdc: w32.HDC, scale: f32) Fonts {
        // The terminal's own font, registered by App from Ghostty's copy.
        const ui = canvas_mod.jetbrains_mono;
        const icon_face = canvas_mod.iconFace(hdc);
        const f = canvas_mod.createFont;
        return .{
            .body = f(13, scale, ui, w32.FW_NORMAL, .cleartype),
            .strong = f(13, scale, ui, w32.FW_BOLD, .cleartype),
            .small = f(12, scale, ui, w32.FW_NORMAL, .cleartype),
            .heading = f(15, scale, ui, w32.FW_BOLD, .cleartype),
            .crumb = f(14, scale, ui, w32.FW_NORMAL, .cleartype),
            .crumb_strong = f(14, scale, ui, w32.FW_BOLD, .cleartype),
            .icons = f(16, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_small = f(10, scale, icon_face, w32.FW_NORMAL, .grayscale),
        };
    }

    pub fn deinit(self: *Fonts) void {
        inline for (.{ &self.body, &self.strong, &self.small, &self.heading, &self.crumb, &self.crumb_strong, &self.icons, &self.icons_small }) |font| {
            if (font.*) |f| _ = w32.DeleteObject(f);
            font.* = null;
        }
    }
};

pub const State = struct {
    category: usize,
    query: []const u8,
    scroll: i32,
    hover: Target,
    focused: bool,
    search_focused: bool,
    caret_visible: bool,
    config_text: []const u8,
    /// Installed shells, for the Shell dropdown's label.
    profiles: *const profiles_mod.List,
};

/// Segoe Fluent Icons code points used by the panel.
const icon_search = 0xE721;
const icon_close = 0xE8BB;
const icon_chevron = 0xE70D;
const icon_restore = 0xE72C;

/// Sizes in pixels at 96 DPI.
const margin = 32.0;
const max_panel_width = 1100.0;
const panel_corner = 12.0;
const sidebar_width = 240.0;
const header_height = 56.0;
const column_width = 760.0;
const row_height = 68.0;
const card_corner = 10.0;
const control_corner = 6.0;
const dropdown_width = 200.0;
const control_height = 32.0;

/// The panel's place inside a window of `width` by `height`.
pub fn panelRect(width: i32, height: i32, scale: f32) w32.RECT {
    const m = px(margin, scale);
    const w = @min(width - 2 * m, px(max_panel_width, scale));
    const left = @divTrunc(width - w, 2);
    return .{ .left = left, .top = m, .right = left + w, .bottom = height - m };
}

pub fn panelCorner(scale: f32) i32 {
    return px(panel_corner, scale);
}

fn px(value: f32, scale: f32) i32 {
    return @intFromFloat(@round(value * scale));
}

const Painter = struct {
    c: Canvas,
    scale: f32,
    palette: Palette,
    fonts: Fonts,
    state: State,
    spots: *Spots,
    body: w32.RECT,

    fn px(self: Painter, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }
};

/// Paint a frame and return how far the content can scroll.
pub fn paint(c: Canvas, scale: f32, palette: Palette, fonts: Fonts, state: State, spots: *Spots) i32 {
    spots.len = 0;
    const full: w32.RECT = .{ .left = 0, .top = 0, .right = c.width, .bottom = c.height };
    spots.add(full, .backdrop);
    // The alpha pass in SettingsPanel turns black outside the panel into
    // the dimmed backdrop and rounds the panel's corners.
    c.fill(full, Rgb.black);

    const p = panelRect(c.width, c.height, scale);
    c.fill(p, palette.panel);
    spots.add(p, .none);

    const side: w32.RECT = .{ .left = p.left, .top = p.top, .right = p.left + px(sidebar_width, scale), .bottom = p.bottom };
    const content: w32.RECT = .{ .left = side.right + 1, .top = p.top, .right = p.right, .bottom = p.bottom };
    const body: w32.RECT = .{ .left = content.left, .top = content.top + px(header_height, scale) + 1, .right = content.right, .bottom = p.bottom };

    var painter: Painter = .{ .c = c, .scale = scale, .palette = palette, .fonts = fonts, .state = state, .spots = spots, .body = body };
    // Content first, so the header and sidebar cover what scrolls past them.
    const content_height = paintBody(&painter);
    paintHeader(&painter, content);
    paintSidebar(&painter, side);
    return @max(0, content_height - (body.bottom - body.top));
}

fn paintBody(p: *Painter) i32 {
    const body = p.body;
    const col_w = @min(body.right - body.left - 2 * p.px(32), p.px(column_width));
    const left = body.left + @divTrunc(body.right - body.left - col_w, 2);
    const top = body.top + p.px(24) - p.state.scroll;
    var y = top;

    if (p.state.query.len == 0) {
        const category = settings.data.categories[p.state.category];
        for (category.sections, 0..) |section, s| {
            var refs: [32]settings.Ref = undefined;
            var n: usize = 0;
            for (section.settings, 0..) |_, i| {
                refs[n] = .{ .category = p.state.category, .section = s, .setting = i };
                n += 1;
            }
            y = paintSection(p, section.title, refs[0..n], left, left + col_w, y);
        }
    } else {
        var any = false;
        for (settings.data.categories, 0..) |category, c| {
            var refs: [32]settings.Ref = undefined;
            var n: usize = 0;
            for (category.sections, 0..) |section, s| {
                for (section.settings, 0..) |setting, i| {
                    if (n < refs.len and settings.matches(setting, p.state.query)) {
                        refs[n] = .{ .category = c, .section = s, .setting = i };
                        n += 1;
                    }
                }
            }
            if (n == 0) continue;
            any = true;
            y = paintSection(p, category.name, refs[0..n], left, left + col_w, y);
        }
        if (!any) {
            p.c.text(.{ .left = left, .top = y, .right = left + col_w, .bottom = y + p.px(40) }, settings.data.no_results, p.fonts.body, p.palette.text_dim, .left);
            y += p.px(40);
        }
    }
    return y - top + p.px(24);
}

fn paintSection(p: *Painter, title: []const u8, refs: []const settings.Ref, left: i32, right: i32, top: i32) i32 {
    var y = top;
    p.c.text(.{ .left = left + p.px(2), .top = y, .right = right, .bottom = y + p.px(32) }, title, p.fonts.heading, p.palette.text, .left);
    y += p.px(40);

    const row_h = p.px(row_height);
    const card: w32.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + row_h * @as(i32, @intCast(refs.len)) };
    p.c.fillRounded(card, p.px(card_corner), p.palette.card);
    for (refs, 0..) |ref, i| {
        const row_top = y + row_h * @as(i32, @intCast(i));
        if (i > 0) p.c.fill(.{ .left = card.left + 1, .top = row_top, .right = card.right - 1, .bottom = row_top + 1 }, p.palette.border);
        paintRow(p, .{ .left = card.left, .top = row_top, .right = card.right, .bottom = row_top + row_h }, ref);
    }
    return card.bottom + p.px(28);
}

fn paintRow(p: *Painter, row: w32.RECT, ref: settings.Ref) void {
    const setting = ref.get();
    const pad = p.px(18);
    const hovered = p.state.hover.eql(.{ .control = ref });
    const pal = p.palette;

    const control_w = switch (setting.kind()) {
        .dropdown => p.px(dropdown_width),
        .toggle => p.px(40),
        .action => p.c.textWidth(setting.button, p.fonts.body) + p.px(32),
    };
    const control_h = if (setting.kind() == .toggle) p.px(22) else p.px(control_height);
    const control: w32.RECT = .{
        .left = row.right - pad - control_w,
        .top = row.top + @divTrunc(row.bottom - row.top - control_h, 2),
        .right = row.right - pad,
        .bottom = row.top + @divTrunc(row.bottom - row.top - control_h, 2) + control_h,
    };

    const text_right = control.left - p.px(16);
    p.c.text(.{ .left = row.left + pad, .top = row.top + p.px(12), .right = text_right, .bottom = row.top + p.px(34) }, setting.label, p.fonts.strong, pal.text, .left);
    p.c.text(.{ .left = row.left + pad, .top = row.top + p.px(34), .right = text_right, .bottom = row.top + p.px(56) }, setting.description, p.fonts.small, pal.text_dim, .left);

    switch (setting.kind()) {
        .dropdown => {
            p.c.fillRounded(control, p.px(control_corner), if (hovered) pal.control_hover else pal.control);
            const label = settings.currentLabel(setting, p.state.config_text, p.state.profiles);
            p.c.text(.{ .left = control.left + p.px(12), .top = control.top, .right = control.right - p.px(30), .bottom = control.bottom }, label, p.fonts.body, pal.text, .left);
            p.c.glyph(.{ .left = control.right - p.px(30), .top = control.top, .right = control.right - p.px(8), .bottom = control.bottom }, icon_chevron, p.fonts.icons_small, pal.text_dim);
        },
        .toggle => {
            const on = settings.toggleIsOn(setting, p.state.config_text);
            const h = control.bottom - control.top;
            const knob = h - p.px(8);
            const knob_left = if (on) control.right - p.px(4) - knob else control.left + p.px(4);
            const knob_rect: w32.RECT = .{ .left = knob_left, .top = control.top + p.px(4), .right = knob_left + knob, .bottom = control.top + p.px(4) + knob };
            if (on) {
                p.c.fillRounded(control, @divTrunc(h, 2), if (hovered) pal.accent.mix(Rgb.white, 0.12) else pal.accent);
                p.c.fillRounded(knob_rect, @divTrunc(knob, 2), Rgb.white);
            } else {
                p.c.fillRounded(control, @divTrunc(h, 2), if (hovered) pal.control_hover else pal.control);
                p.c.fillRounded(knob_rect, @divTrunc(knob, 2), pal.text_dim);
            }
        },
        .action => {
            p.c.fillRounded(control, p.px(control_corner), if (hovered) pal.control_hover else pal.control);
            p.c.text(control, setting.button, p.fonts.body, pal.text, .center);
        },
    }

    // Only the part of a control inside the scrolling body is clickable.
    const body = p.body;
    const visible: w32.RECT = .{ .left = control.left, .top = @max(control.top, body.top), .right = control.right, .bottom = @min(control.bottom, body.bottom) };
    if (visible.bottom > visible.top) p.spots.add(visible, .{ .control = ref });
}

fn paintHeader(p: *Painter, content: w32.RECT) void {
    const pal = p.palette;
    const header: w32.RECT = .{ .left = content.left, .top = content.top, .right = content.right, .bottom = p.body.top };
    p.c.fill(header, pal.panel);
    p.c.fill(.{ .left = header.left, .top = header.bottom - 1, .right = header.right, .bottom = header.bottom }, pal.border);
    p.spots.add(header, .none);

    // Breadcrumb: "Settings / General", or "Settings / Search".
    const title = settings.data.title;
    const current = if (p.state.query.len > 0) settings.data.search_placeholder else settings.data.categories[p.state.category].name;
    var x = header.left + p.px(24);
    const line: w32.RECT = .{ .left = x, .top = header.top, .right = header.right, .bottom = header.bottom - 1 };
    p.c.text(line, title, p.fonts.crumb, pal.text_dim, .left);
    x += p.c.textWidth(title, p.fonts.crumb) + p.px(10);
    p.c.text(.{ .left = x, .top = line.top, .right = line.right, .bottom = line.bottom }, "/", p.fonts.crumb, pal.text_dim, .left);
    x += p.c.textWidth("/", p.fonts.crumb) + p.px(10);
    p.c.text(.{ .left = x, .top = line.top, .right = line.right - p.px(240), .bottom = line.bottom }, current, p.fonts.crumb_strong, pal.text, .left);

    const size = p.px(32);
    const mid = header.top + @divTrunc(header.bottom - header.top - size, 2);
    const close: w32.RECT = .{ .left = header.right - p.px(14) - size, .top = mid, .right = header.right - p.px(14), .bottom = mid + size };
    if (p.state.hover.eql(.close)) p.c.fillRounded(close, p.px(control_corner), pal.panel_hover);
    p.c.glyph(close, icon_close, p.fonts.icons_small, pal.text);
    p.spots.add(close, .close);

    const label = settings.data.restore_label;
    const restore_w = p.c.textWidth(label, p.fonts.body) + p.px(40);
    const restore: w32.RECT = .{ .left = close.left - p.px(6) - restore_w, .top = mid, .right = close.left - p.px(6), .bottom = mid + size };
    if (p.state.hover.eql(.restore)) p.c.fillRounded(restore, p.px(control_corner), pal.panel_hover);
    p.c.glyph(.{ .left = restore.left + p.px(8), .top = restore.top, .right = restore.left + p.px(28), .bottom = restore.bottom }, icon_restore, p.fonts.icons_small, pal.text);
    p.c.text(.{ .left = restore.left + p.px(32), .top = restore.top, .right = restore.right, .bottom = restore.bottom }, label, p.fonts.body, pal.text, .left);
    p.spots.add(restore, .restore);
}

fn paintSidebar(p: *Painter, side: w32.RECT) void {
    const pal = p.palette;
    p.c.fill(side, pal.sidebar);
    p.spots.add(side, .none);

    const search: w32.RECT = .{ .left = side.left + p.px(12), .top = side.top + p.px(12), .right = side.right - p.px(12), .bottom = side.top + p.px(48) };
    const searching = p.state.query.len > 0;
    const search_fill = if (p.state.search_focused)
        pal.selected
    else if (p.state.hover.eql(.search)) pal.hover else pal.sidebar.mix(pal.text, 0.05);
    p.c.fillRounded(search, p.px(8), search_fill);
    p.c.glyph(.{ .left = search.left + p.px(8), .top = search.top, .right = search.left + p.px(30), .bottom = search.bottom }, icon_search, p.fonts.icons_small, pal.text_dim);
    const text_rect: w32.RECT = .{ .left = search.left + p.px(36), .top = search.top, .right = search.right - p.px(8), .bottom = search.bottom };
    if (searching) {
        p.c.text(text_rect, p.state.query, p.fonts.body, pal.text, .left);
    } else {
        p.c.text(text_rect, settings.data.search_placeholder, p.fonts.body, pal.text_dim, .left);
    }
    if (p.state.search_focused and p.state.focused and p.state.caret_visible) {
        // With no query the caret sits just before the placeholder.
        const after = if (searching) p.c.textWidth(p.state.query, p.fonts.body) + 1 else -p.px(3);
        const caret_x = @min(text_rect.left + after, text_rect.right);
        const h = p.px(16);
        const t = search.top + @divTrunc(search.bottom - search.top - h, 2);
        p.c.fill(.{ .left = caret_x, .top = t, .right = caret_x + @max(1, p.px(1)), .bottom = t + h }, pal.text);
    }
    p.spots.add(search, .search);

    var y = search.bottom + p.px(14);
    for (settings.data.categories, 0..) |category, i| {
        const item: w32.RECT = .{ .left = side.left + p.px(8), .top = y, .right = side.right - p.px(8), .bottom = y + p.px(36) };
        const selected = !searching and i == p.state.category;
        if (selected) {
            p.c.fillRounded(item, p.px(control_corner), pal.selected);
        } else if (p.state.hover.eql(.{ .category = i })) {
            p.c.fillRounded(item, p.px(control_corner), pal.hover);
        }
        p.c.glyph(.{ .left = item.left + p.px(8), .top = item.top, .right = item.left + p.px(32), .bottom = item.bottom }, category.icon, p.fonts.icons, if (selected) pal.text else pal.text_dim);
        p.c.text(.{ .left = item.left + p.px(40), .top = item.top, .right = item.right - p.px(8), .bottom = item.bottom }, category.name, if (selected) p.fonts.strong else p.fonts.body, pal.text, .left);
        p.spots.add(item, .{ .category = i });
        y += p.px(40);
    }
}
