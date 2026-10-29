const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const SearchField = @import("SearchField.zig");
const BrowserTab = @import("BrowserTab.zig");
const toolbar = @import("browser_toolbar.zig");
const browser_settings = @import("browser_settings.zig");

const Target = toolbar.Target;
const labels = browser_settings.data.dialog;

const bar_height = 40.0;
const button_width = 76.0;
const button_height = 28.0;
const gap = 8.0;

pub const Layout = struct {
    scale: f32,
    left: i32,
    top: i32,
    width: i32,
    kind: BrowserTab.DialogKind,

    fn px(self: Layout, value: f32) i32 {
        return @intFromFloat(@round(value * self.scale));
    }

    pub fn height(scale: f32) i32 {
        return @intFromFloat(@round(bar_height * scale));
    }

    fn bottom(self: Layout) i32 {
        return self.top + height(self.scale);
    }

    fn hasCancel(self: Layout) bool {
        return self.kind != .alert;
    }

    fn button(self: Layout, slot: i32) w32.RECT {
        const right = self.width - self.px(gap) - slot * (self.px(button_width) + self.px(gap));
        const top = self.top + @divTrunc(height(self.scale) - self.px(button_height), 2);
        return .{ .left = right - self.px(button_width), .top = top, .right = right, .bottom = top + self.px(button_height) };
    }

    fn buttonsLeft(self: Layout) i32 {
        return self.button(if (self.hasCancel()) 1 else 0).left - self.px(gap);
    }

    pub fn rect(self: Layout, target: Target) w32.RECT {
        return switch (target) {
            .dialog_ok => self.button(0),
            .dialog_cancel => self.button(1),
            .dialog_field => blk: {
                const ok = self.button(0);
                const left = self.left + @divTrunc(self.buttonsLeft() - self.left, 2);
                break :blk .{ .left = left, .top = ok.top, .right = self.buttonsLeft(), .bottom = ok.bottom };
            },
            else => .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
    }

    fn messageRect(self: Layout) w32.RECT {
        const right = if (self.kind == .prompt) self.rect(.dialog_field).left - self.px(gap) else self.buttonsLeft();
        return .{ .left = self.left + self.px(gap * 1.5), .top = self.top, .right = right, .bottom = self.bottom() };
    }

    pub fn hit(self: Layout, x: i32, y: i32) Target {
        if (y < self.top or y >= self.bottom()) return .none;
        for ([_]Target{ .dialog_ok, .dialog_cancel, .dialog_field }) |t| {
            if (t == .dialog_cancel and !self.hasCancel()) continue;
            if (t == .dialog_field and self.kind != .prompt) continue;
            const r = self.rect(t);
            if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return t;
        }
        return .none;
    }
};

pub const View = struct {
    palette: tab_strip.Palette,
    fonts: tab_strip.Fonts,
    message: []const u8,
    field: *const SearchField,
    hover: Target,
    pressed: Target,
};

pub fn paint(c: canvas_mod.Canvas, layout: Layout, view: View) void {
    const pal = view.palette;
    c.fill(.{ .left = layout.left, .top = layout.top, .right = layout.width, .bottom = layout.bottom() }, pal.strip.mix(pal.contrast, 0.04));
    c.fill(.{ .left = layout.left, .top = layout.bottom() - @max(1, layout.px(1)), .right = layout.width, .bottom = layout.bottom() }, pal.separator);
    var buf: [600]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: {s}", .{ labels.says, firstLine(view.message) }) catch view.message;
    c.text(layout.messageRect(), line, view.fonts.title, pal.text, .left);
    if (layout.kind == .prompt) {
        c.sync();
        view.field.paint(c, layout.rect(.dialog_field), layout.scale, .{
            .fill = pal.strip.mix(pal.contrast, 0.08),
            .hover = pal.hover,
            .focused = pal.hover.mix(pal.contrast, 0.05),
            .text = pal.text,
            .text_dim = pal.text_dim,
            .font = view.fonts.title,
            .icon_font = view.fonts.icons_small,
            .placeholder = "",
            .icon = 0xE70F,
        }, view.hover == .dialog_field, true);
    }
    const leaving = layout.kind == .beforeunload;
    paintButton(c, layout, view, .dialog_ok, if (leaving) labels.leave else labels.ok, true);
    if (layout.hasCancel()) paintButton(c, layout, view, .dialog_cancel, if (leaving) labels.stay else labels.cancel, false);
    c.sync();
}

fn paintButton(c: canvas_mod.Canvas, layout: Layout, view: View, target: Target, label: []const u8, primary: bool) void {
    const pal = view.palette;
    const r = layout.rect(target);
    const base = if (primary) pal.hover.mix(pal.contrast, 0.1) else pal.hover;
    const fill = if (view.pressed.eql(target)) pal.pressed else if (view.hover.eql(target)) base.mix(pal.contrast, 0.08) else base;
    c.sync();
    c.fillRounded(r, layout.px(6), fill);
    c.text(r, label, view.fonts.title, pal.text, .center);
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return text[0..end];
}
