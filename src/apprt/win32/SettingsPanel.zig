//! The settings panel: a layered window over the owner's terminal area
//! that dims the terminal and shows settings_view on top. It owns the
//! panel's input and state; picks are written to the config file, and the
//! host reloads them.
const SettingsPanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const canvas_mod = @import("canvas.zig");
const config_file = @import("config_file.zig");
const settings = @import("settings.zig");
const view = @import("settings_view.zig");

const Rgb = canvas_mod.Rgb;
const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Settings");

/// How dark the terminal behind the panel gets, out of 255.
const backdrop_alpha = 110;
/// Pixels scrolled per wheel notch at 96 DPI.
const wheel_step = 48.0;

/// What the panel needs from the window that opened it.
pub const Host = struct {
    ctx: *anyopaque,
    /// Re-read the config file and apply it everywhere.
    reload: *const fn (*anyopaque) void,
    /// Open the config file in an editor.
    edit_file: *const fn (*anyopaque) void,
    /// The terminal's current background and foreground.
    colors: *const fn (*anyopaque) [2]Rgb,
    /// The panel's window is gone; the host may free the panel.
    closed: *const fn (*anyopaque) void,
};

hwnd: ?w32.HWND = null,
owner: w32.HWND,
host: Host,
alloc: Allocator,
scale: f32,
/// Screen rectangle the panel covers.
area: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
fonts: view.Fonts = .{},
palette: view.Palette = undefined,
config_text: []u8 = &.{},
category: usize = 0,
query: [64]u8 = undefined,
query_len: usize = 0,
scroll: i32 = 0,
max_scroll: i32 = 0,
hover: view.Target = .none,
spots: view.Spots = .{},
tracking_mouse: bool = false,
focused: bool = true,

pub fn registerClass(instance: w32.HINSTANCE) !u16 {
    const atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    if (atom == 0) return error.Win32Error;
    return atom;
}

/// Create and show the panel over `area` (screen pixels).
pub fn open(self: *SettingsPanel, instance: w32.HINSTANCE, area: w32.RECT) !void {
    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        area.left,
        area.top,
        area.right - area.left,
        area.bottom - area.top,
        self.owner,
        null,
        instance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    if (w32.GetDC(hwnd)) |hdc| {
        defer _ = w32.ReleaseDC(hwnd, hdc);
        self.fonts = .init(hdc, self.scale);
    }
    self.refresh();
    self.place(area);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetFocus(hwnd);
}

pub fn close(self: *SettingsPanel) void {
    if (self.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
}

/// Follow the owner when it moves or resizes.
pub fn place(self: *SettingsPanel, area: w32.RECT) void {
    self.area = area;
    self.render();
}

pub fn focus(self: *SettingsPanel) void {
    if (self.hwnd) |hwnd| _ = w32.SetFocus(hwnd);
}

/// Re-read the config file and the colors, which a change may alter.
fn refresh(self: *SettingsPanel) void {
    self.alloc.free(self.config_text);
    self.config_text = config_file.read(self.alloc) catch |err| blk: {
        log.warn("settings panel could not read the config file: {}", .{err});
        break :blk &.{};
    };
    const colors = self.host.colors(self.host.ctx);
    self.palette = .fromTerminal(colors[0], colors[1], accentColor());
}

/// The Windows accent color, for switched-on toggles.
fn accentColor() Rgb {
    var argb: u32 = 0;
    var opaque_blend: i32 = 0;
    if (w32.DwmGetColorizationColor(&argb, &opaque_blend) < 0) return .{ .r = 0x00, .g = 0x67, .b = 0xC0 };
    return .{ .r = @truncate(argb >> 16), .g = @truncate(argb >> 8), .b = @truncate(argb) };
}

fn render(self: *SettingsPanel) void {
    const hwnd = self.hwnd orelse return;
    const width = self.area.right - self.area.left;
    const height = self.area.bottom - self.area.top;
    if (width <= 0 or height <= 0) return;

    const mem_dc = w32.CreateCompatibleDC(null) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(mem_dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(bitmap);
    const old = w32.SelectObject(mem_dc, bitmap);
    defer _ = w32.SelectObject(mem_dc, old);

    const canvas: canvas_mod.Canvas = .{ .hdc = mem_dc, .pixels = @ptrCast(@alignCast(bits orelse return)), .width = width, .height = height };
    self.max_scroll = view.paint(canvas, self.scale, self.palette, self.fonts, .{
        .category = self.category,
        .query = self.query[0..self.query_len],
        .scroll = self.scroll,
        .hover = self.hover,
        .focused = self.focused,
        .config_text = self.config_text,
    }, &self.spots);
    canvas.sync();
    applyAlpha(canvas, view.panelRect(width, height, self.scale), view.panelCorner(self.scale));

    const pos: w32.POINT = .{ .x = self.area.left, .y = self.area.top };
    const size: w32.SIZE = .{ .cx = width, .cy = height };
    const origin: w32.POINT = .{ .x = 0, .y = 0 };
    const blend: w32.BLENDFUNCTION = .{};
    _ = w32.UpdateLayeredWindow(hwnd, null, &pos, &size, mem_dc, &origin, 0, &blend, w32.ULW_ALPHA);
}

/// The view paints opaque colors over black. Turn that into the
/// premultiplied alpha a layered window needs: a dim backdrop outside the
/// panel, an opaque panel inside, and anti-aliased rounded corners.
fn applyAlpha(c: canvas_mod.Canvas, panel: w32.RECT, radius: i32) void {
    const dim: u32 = backdrop_alpha << 24;
    var y: i32 = 0;
    while (y < c.height) : (y += 1) {
        const row = c.pixels[@intCast(y * c.width)..@intCast((y + 1) * c.width)];
        if (y < panel.top or y >= panel.bottom) {
            @memset(row, dim);
            continue;
        }
        @memset(row[0..@intCast(@max(panel.left, 0))], dim);
        @memset(row[@intCast(@min(panel.right, c.width))..], dim);
        for (row[@intCast(@max(panel.left, 0))..@intCast(@min(panel.right, c.width))]) |*p| p.* |= 0xFF000000;
    }

    const corners = [_]struct { x: i32, y: i32, center: [2]u1 }{
        .{ .x = panel.left, .y = panel.top, .center = .{ 1, 1 } },
        .{ .x = panel.right - radius, .y = panel.top, .center = .{ 0, 1 } },
        .{ .x = panel.left, .y = panel.bottom - radius, .center = .{ 1, 0 } },
        .{ .x = panel.right - radius, .y = panel.bottom - radius, .center = .{ 0, 0 } },
    };
    for (corners) |corner| {
        var py: i32 = 0;
        while (py < radius) : (py += 1) {
            var px_: i32 = 0;
            while (px_ < radius) : (px_ += 1) {
                const x = corner.x + px_;
                const yy = corner.y + py;
                if (x < 0 or yy < 0 or x >= c.width or yy >= c.height) continue;
                const cov = canvas_mod.cornerCoverage(px_, py, radius, corner.center);
                const p = &c.pixels[@intCast(yy * c.width + x)];
                const color = Rgb.fromPixel(p.*);
                const premul: Rgb = .{
                    .r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * cov),
                    .g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * cov),
                    .b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * cov),
                };
                const alpha: u32 = @intFromFloat(@round(cov * 255 + (1 - cov) * backdrop_alpha));
                p.* = premul.toPixel() | (alpha << 24);
            }
        }
    }
}

fn setHover(self: *SettingsPanel, target: view.Target) void {
    if (target.eql(self.hover)) return;
    self.hover = target;
    self.render();
}

fn targetAt(self: *SettingsPanel, x: i32, y: i32) ?view.Spots.Spot {
    return self.spots.at(x, y);
}

fn click(self: *SettingsPanel, x: i32, y: i32) void {
    const spot = self.targetAt(x, y) orelse return;
    switch (spot.target) {
        .none, .search => {},
        .backdrop, .close => self.close(),
        .restore => self.restoreDefaults(),
        .category => |i| {
            self.category = i;
            self.query_len = 0;
            self.scroll = 0;
            self.render();
        },
        .control => |ref| self.useControl(ref, spot.rect),
    }
}

fn useControl(self: *SettingsPanel, ref: settings.Ref, rect: w32.RECT) void {
    const setting = ref.get();
    switch (setting.kind()) {
        .dropdown => {
            const hwnd = self.hwnd orelse return;
            var below: w32.POINT = .{ .x = rect.left, .y = rect.bottom + @as(i32, @intFromFloat(@round(4 * self.scale))) };
            _ = w32.ClientToScreen(hwnd, &below);
            const value = settings.pickChoice(hwnd, below, setting, self.config_text, self.palette.dark) orelse return;
            self.change(setting.key, value);
        },
        .toggle => {
            const on = settings.toggleIsOn(setting, self.config_text);
            self.change(setting.key, if (on) setting.off.? else setting.on.?);
        },
        .action => switch (setting.action.?) {
            .edit_file => self.host.edit_file(self.host.ctx),
            .reload => {
                self.host.reload(self.host.ctx);
                self.refresh();
                self.render();
            },
        },
    }
}

fn change(self: *SettingsPanel, key: []const u8, value: []const u8) void {
    config_file.write(self.alloc, key, value) catch |err| {
        log.err("failed to save setting {s}: {}", .{ key, err });
        return;
    };
    self.host.reload(self.host.ctx);
    self.refresh();
    self.render();
}

/// Remove every key the panel manages, after asking.
fn restoreDefaults(self: *SettingsPanel) void {
    var message: [512]u16 = undefined;
    _ = @import("wide_string.zig").fromUtf8(&message, settings.data.restore_confirm);
    const answer = w32.MessageBoxW(self.hwnd, @ptrCast(&message), std.unicode.utf8ToUtf16LeStringLiteral(brand.name), w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2);
    if (answer != w32.IDOK) return;
    for (settings.data.categories) |category| {
        for (category.sections) |section| {
            for (section.settings) |setting| {
                if (setting.key.len == 0) continue;
                config_file.write(self.alloc, setting.key, "") catch |err| {
                    log.err("failed to reset setting {s}: {}", .{ setting.key, err });
                };
            }
        }
    }
    self.host.reload(self.host.ctx);
    self.refresh();
    self.render();
}

fn typeChar(self: *SettingsPanel, char: u16) void {
    if (char < 0x20 or char == 0x7F or (char >= 0xD800 and char <= 0xDFFF)) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &buf) catch return;
    if (self.query_len + len > self.query.len) return;
    @memcpy(self.query[self.query_len..][0..len], buf[0..len]);
    self.query_len += len;
    self.scroll = 0;
    self.render();
}

fn backspace(self: *SettingsPanel) void {
    if (self.query_len == 0) return;
    // Drop one whole UTF-8 character.
    var i = self.query_len - 1;
    while (i > 0 and self.query[i] & 0xC0 == 0x80) i -= 1;
    self.query_len = i;
    self.render();
}

fn scrollBy(self: *SettingsPanel, delta: i32) void {
    const next = std.math.clamp(self.scroll + delta, 0, self.max_scroll);
    if (next == self.scroll) return;
    self.scroll = next;
    self.render();
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SettingsPanel = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));

    switch (msg) {
        w32.WM_MOUSEMOVE => {
            if (!self.tracking_mouse) {
                var tme = w32.TRACKMOUSEEVENT{ .cbSize = @sizeOf(w32.TRACKMOUSEEVENT), .dwFlags = w32.TME_LEAVE, .hwndTrack = hwnd, .dwHoverTime = 0 };
                _ = w32.TrackMouseEvent(&tme);
                self.tracking_mouse = true;
            }
            self.setHover(if (self.targetAt(x, y)) |spot| spot.target else .none);
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.setHover(.none);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            self.click(x, y);
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            const notches: i32 = @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16))));
            self.scrollBy(-@divTrunc(notches * @as(i32, @intFromFloat(@round(wheel_step * self.scale))), 120));
            return 0;
        },
        w32.WM_SETCURSOR => {
            const clickable = switch (self.hover) {
                .none, .backdrop, .search => false,
                else => true,
            };
            if (clickable) {
                if (w32.LoadCursorW(null, w32.IDC_HAND)) |cursor| _ = w32.SetCursor(cursor);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_KEYDOWN => {
            switch (@as(u16, @truncate(wparam))) {
                w32.VK_ESCAPE => if (self.query_len > 0) {
                    self.query_len = 0;
                    self.render();
                } else self.close(),
                w32.VK_BACK => self.backspace(),
                else => {},
            }
            return 0;
        },
        w32.WM_CHAR => {
            self.typeChar(@truncate(wparam));
            return 0;
        },
        w32.WM_SETFOCUS, w32.WM_KILLFOCUS => {
            self.focused = msg == w32.WM_SETFOCUS;
            self.render();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.hwnd = null;
            self.fonts.deinit();
            self.alloc.free(self.config_text);
            self.config_text = &.{};
            self.host.closed(self.host.ctx);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
