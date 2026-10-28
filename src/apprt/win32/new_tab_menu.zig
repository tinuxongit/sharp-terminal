//! The menu behind the arrow beside "+": the installed shell profiles with
//! their icons and Ctrl+Shift+N shortcuts, then settings, the command
//! palette and about, as in Windows Terminal. The shortcuts themselves are
//! handled by App; this only shows them.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const profiles = @import("profiles.zig");
const menu_theme = @import("menu_theme.zig");
const wide_string = @import("wide_string.zig");

const Rgb = canvas_mod.Rgb;

pub const Pick = union(enum) {
    profile: usize,
    settings,
    command_palette,
    about,
};

const id_settings = 1;
const id_command_palette = 2;
const id_about = 3;
const id_profile_base = 100;

/// Segoe Fluent Icons code points for the fixed entries.
const icon_settings = 0xE713;
const icon_command_palette = 0xE945;
const icon_about = 0xE946;

/// Show the menu with its top-left corner at `point` (screen pixels).
/// `selected` is the profile new tabs use, shown in bold.
pub fn show(owner: w32.HWND, point: w32.POINT, list: *const profiles.List, selected: ?usize, icons: *profiles.Icons, scale: f32, dark: bool) ?Pick {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    // Icons take the place of check marks instead of adding a column.
    _ = w32.SetMenuInfo(menu, &.{ .fMask = w32.MIM_STYLE, .dwStyle = w32.MNS_CHECKORBMP });

    const size: i32 = @intFromFloat(@round(16 * scale));
    var bitmaps: [profiles.List.max_profiles + 3]?*anyopaque = @splat(null);
    defer {
        for (bitmaps) |b| {
            if (b) |bitmap| _ = w32.DeleteObject(bitmap);
        }
    }

    var position: u32 = 0;
    for (0..list.len) |i| {
        const name = list.name(i);
        bitmaps[i] = if (icons.get(list.icon(i), size)) |icon| iconBitmap(icon, size) else null;
        var label: [160]u8 = undefined;
        const text = if (i < 9)
            std.fmt.bufPrint(&label, "{s}\t{s}{d}", .{ name, profiles.data.menu.profile_shortcut, i + 1 }) catch name
        else
            name;
        insert(menu, &position, id_profile_base + @as(u32, @intCast(i)), text, bitmaps[i], selected == i);
    }
    var separator: w32.MENUITEMINFOW = .{ .fMask = w32.MIIM_FTYPE, .fType = w32.MFT_SEPARATOR };
    _ = w32.InsertMenuItemW(menu, position, 1, &separator);
    position += 1;

    const text_color: Rgb = if (dark) .{ .r = 0xE6, .g = 0xE6, .b = 0xE6 } else .{ .r = 0x1F, .g = 0x1F, .b = 0x1F };
    const m = profiles.data.menu;
    const fixed = [_]struct { id: u32, icon: u16, label: []const u8, shortcut: []const u8 }{
        .{ .id = id_settings, .icon = icon_settings, .label = m.settings, .shortcut = m.settings_shortcut },
        .{ .id = id_command_palette, .icon = icon_command_palette, .label = m.command_palette, .shortcut = m.command_palette_shortcut },
        .{ .id = id_about, .icon = icon_about, .label = m.about, .shortcut = "" },
    };
    for (fixed, 0..) |entry, i| {
        const slot = list.len + i;
        bitmaps[slot] = glyphBitmap(owner, entry.icon, size, text_color);
        var label: [160]u8 = undefined;
        const text = if (entry.shortcut.len > 0)
            std.fmt.bufPrint(&label, "{s}\t{s}", .{ entry.label, entry.shortcut }) catch entry.label
        else
            entry.label;
        insert(menu, &position, entry.id, text, bitmaps[slot], false);
    }

    menu_theme.apply(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked <= 0) return null;
    const id: u32 = @intCast(picked);
    return switch (id) {
        id_settings => .settings,
        id_command_palette => .command_palette,
        id_about => .about,
        else => if (id >= id_profile_base and id - id_profile_base < list.len) .{ .profile = id - id_profile_base } else null,
    };
}

fn insert(menu: w32.HMENU, position: *u32, id: u32, label: []const u8, bitmap: ?*anyopaque, bold: bool) void {
    var buf: [160]u16 = undefined;
    _ = wide_string.fromUtf8(&buf, label);
    const item: w32.MENUITEMINFOW = .{
        .fMask = w32.MIIM_ID | w32.MIIM_STRING | w32.MIIM_FTYPE | w32.MIIM_STATE | (if (bitmap != null) w32.MIIM_BITMAP else 0),
        .fType = w32.MFT_STRING,
        .fState = if (bold) w32.MFS_DEFAULT else 0,
        .wID = id,
        .dwTypeData = @ptrCast(&buf),
        .hbmpItem = bitmap,
    };
    _ = w32.InsertMenuItemW(menu, position.*, 1, &item);
    position.* += 1;
}

/// Menus need a 32-bit premultiplied bitmap to show an icon with soft edges.
fn newBitmap(size: i32) ?struct { dc: w32.HDC, bitmap: *anyopaque, pixels: [*]u32 } {
    const dc = w32.CreateCompatibleDC(null) orelse return null;
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = size, .biHeight = -size } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = w32.DeleteDC(dc);
        return null;
    };
    _ = w32.SelectObject(dc, bitmap);
    return .{ .dc = dc, .bitmap = bitmap, .pixels = @ptrCast(@alignCast(bits orelse return null)) };
}

fn iconBitmap(icon: w32.HICON, size: i32) ?*anyopaque {
    const target = newBitmap(size) orelse return null;
    defer _ = w32.DeleteDC(target.dc);
    _ = w32.DrawIconEx(target.dc, 0, 0, icon, size, size, 0, null, w32.DI_NORMAL);
    _ = w32.GdiFlush();
    // Old icons without an alpha channel leave alpha at zero: make them opaque.
    const pixels = target.pixels[0..@intCast(size * size)];
    for (pixels) |p| {
        if (p >> 24 != 0) return target.bitmap;
    }
    for (pixels) |*p| {
        if (p.* != 0) p.* |= 0xFF000000;
    }
    return target.bitmap;
}

/// Draw an icon-font glyph white on black, then use its brightness as the
/// alpha of `color`.
fn glyphBitmap(owner: w32.HWND, code: u16, size: i32, color: Rgb) ?*anyopaque {
    const target = newBitmap(size) orelse return null;
    defer _ = w32.DeleteDC(target.dc);
    const face = face: {
        const hdc = w32.GetDC(owner) orelse return target.bitmap;
        defer _ = w32.ReleaseDC(owner, hdc);
        break :face canvas_mod.iconFace(hdc);
    };
    const font = canvas_mod.createFont(@floatFromInt(size), 1, face, w32.FW_NORMAL, .grayscale) orelse return target.bitmap;
    defer _ = w32.DeleteObject(font);
    const canvas: canvas_mod.Canvas = .{ .hdc = target.dc, .pixels = target.pixels, .width = size, .height = size };
    canvas.glyph(.{ .left = 0, .top = 0, .right = size, .bottom = size }, code, font, Rgb.white);
    canvas.sync();
    for (target.pixels[0..@intCast(size * size)]) |*p| {
        const a: u32 = @max(p.* & 0xFF, (p.* >> 8) & 0xFF, (p.* >> 16) & 0xFF);
        const r = @as(u32, color.r) * a / 255;
        const g = @as(u32, color.g) * a / 255;
        const b = @as(u32, color.b) * a / 255;
        p.* = (a << 24) | (r << 16) | (g << 8) | b;
    }
    return target.bitmap;
}
