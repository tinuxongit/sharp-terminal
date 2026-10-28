//! A tab's color, picked from its right-click menu as in Windows Terminal
//! (colors and text in tab_colors.zon). The color is kept on the tab's
//! panes, as their icon is (Window.tabColor), and the strip tints the tab
//! with it.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas = @import("canvas.zig");
const menu_theme = @import("menu_theme.zig");
const new_tab_menu = @import("new_tab_menu.zig");
const wide_string = @import("wide_string.zig");

pub const Rgb = canvas.Rgb;

const Data = struct {
    menu: []const u8,
    none: []const u8,
    colors: []const struct { name: []const u8, r: u8, g: u8, b: u8 },
};

pub const data: Data = @import("tab_colors.zon");

comptime {
    if (data.colors.len == 0 or data.colors.len > 32) @compileError("tab_colors.zon: between 1 and 32 colors");
}

pub const Choice = union(enum) { none, color: Rgb };

const id_none = 1;
const id_base = 10;

/// The color picker, its top-left corner at `point` (screen pixels).
/// `current` is checked. Null when nothing was picked.
pub fn pick(owner: w32.HWND, point: w32.POINT, current: ?Rgb, scale: f32, dark: bool) ?Choice {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    _ = w32.SetMenuInfo(menu, &.{ .fMask = w32.MIM_STYLE, .dwStyle = w32.MNS_CHECKORBMP });

    const size: i32 = @intFromFloat(@round(16 * scale));
    var swatches: [32]?*anyopaque = @splat(null);
    defer for (swatches) |s| {
        if (s) |bitmap| _ = w32.DeleteObject(bitmap);
    };
    for (data.colors, 0..) |c, i| {
        const rgb: Rgb = .{ .r = c.r, .g = c.g, .b = c.b };
        swatches[i] = swatch(rgb, size);
        const checked = if (current) |cur| std.meta.eql(cur, rgb) else false;
        append(menu, id_base + @as(u32, @intCast(i)), c.name, swatches[i], checked);
    }
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    append(menu, id_none, data.none, null, current == null);

    menu_theme.apply(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked == id_none) return .none;
    if (picked < id_base or picked - id_base >= data.colors.len) return null;
    const c = data.colors[@intCast(picked - id_base)];
    return .{ .color = .{ .r = c.r, .g = c.g, .b = c.b } };
}

fn append(menu: w32.HMENU, id: u32, label: []const u8, bitmap: ?*anyopaque, bold: bool) void {
    var buf: [64]u16 = undefined;
    _ = wide_string.fromUtf8(&buf, label);
    const item: w32.MENUITEMINFOW = .{
        .fMask = w32.MIIM_ID | w32.MIIM_STRING | w32.MIIM_FTYPE | w32.MIIM_STATE | (if (bitmap != null) w32.MIIM_BITMAP else 0),
        .fType = w32.MFT_STRING,
        .fState = if (bold) w32.MFS_DEFAULT else 0,
        .wID = id,
        .dwTypeData = @ptrCast(&buf),
        .hbmpItem = bitmap,
    };
    _ = w32.InsertMenuItemW(menu, w32.GetMenuItemCount(menu), 1, &item);
}

/// A rounded square of `rgb`, premultiplied as menus want it.
fn swatch(rgb: Rgb, size: i32) ?*anyopaque {
    const target = new_tab_menu.newBitmap(size) orelse return null;
    defer _ = w32.DeleteDC(target.dc);
    const n: usize = @intCast(size);
    const inset = @as(f32, @floatFromInt(size)) * 0.12;
    const radius = @as(f32, @floatFromInt(size)) * 0.22;
    for (0..n) |y| for (0..n) |x| {
        // Coverage of a rounded square, sampled at the pixel's center.
        const fx = @as(f32, @floatFromInt(x)) + 0.5;
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const lo = inset + radius;
        const hi = @as(f32, @floatFromInt(size)) - inset - radius;
        const dx = @max(lo - fx, 0, fx - hi);
        const dy = @max(lo - fy, 0, fy - hi);
        const coverage = std.math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
        const a: u32 = @intFromFloat(@round(coverage * 255));
        const scaled = struct {
            fn f(v: u8, alpha: u32) u32 {
                return @as(u32, v) * alpha / 255;
            }
        }.f;
        target.pixels[y * n + x] = (a << 24) | (scaled(rgb.r, a) << 16) | (scaled(rgb.g, a) << 8) | scaled(rgb.b, a);
    };
    return target.bitmap;
}
