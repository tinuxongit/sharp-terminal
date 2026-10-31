//! The menus behind the arrows beside "+": the installed shell profiles
//! with their icons and Ctrl+Shift+N shortcuts, as in Windows Terminal, and
//! for the sidebar's Servers the SSH servers to connect to. The shortcuts
//! themselves are handled by App; this only shows them.
const std = @import("std");
const w32 = @import("win32.zig");
const profiles = @import("profiles.zig");
const menu_theme = @import("menu_theme.zig");
const wide_string = @import("wide_string.zig");

const id_profile_base = 100;

/// Show the menu with its top-left corner at `point` (screen pixels).
/// `selected` is the profile new tabs use, shown in bold. Returns the index
/// of the profile picked.
pub fn show(owner: w32.HWND, point: w32.POINT, list: *const profiles.List, selected: ?usize, icons: *profiles.Icons, scale: f32, dark: bool) ?usize {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    // Icons take the place of check marks instead of adding a column.
    _ = w32.SetMenuInfo(menu, &.{ .fMask = w32.MIM_STYLE, .dwStyle = w32.MNS_CHECKORBMP });

    const size: i32 = @intFromFloat(@round(16 * scale));
    var bitmaps: [profiles.List.max_profiles]?*anyopaque = @splat(null);
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
    menu_theme.apply(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked <= 0) return null;
    const id: u32 = @intCast(picked);
    if (id < id_profile_base or id - id_profile_base >= list.len) return null;
    return id - id_profile_base;
}

/// Show the servers from the SSH config, then those used recently, with
/// the top-left corner at `point`. Returns the one picked.
pub const PickedServer = struct {
    name: []const u8,
    nearby: bool,
};

pub fn showServers(owner: w32.HWND, point: w32.POINT, configured: []const []const u8, recent: []const []const u8, nearby: []const []const u8, nearby_labels: []const []const u8, searching: bool, dark: bool) ?PickedServer {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);

    var position: u32 = 0;
    for (configured, 0..) |name, i| insert(menu, &position, id_profile_base + @as(u32, @intCast(i)), name, null, false);
    if (configured.len > 0 and recent.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        position += 1;
    }
    for (recent, 0..) |name, i| insert(menu, &position, id_profile_base + @as(u32, @intCast(configured.len + i)), name, null, false);
    const nearby_base = id_profile_base + @as(u32, @intCast(configured.len + recent.len));
    if (nearby.len > 0 or searching) {
        if (position > 0) {
            _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
            position += 1;
        }
        var heading: [96]u16 = undefined;
        _ = wide_string.fromUtf8(&heading, if (nearby.len == 0) profiles.data.sidebar.server_menu.searching else profiles.data.sidebar.server_menu.nearby);
        _ = w32.AppendMenuW(menu, w32.MF_GRAYED, 0, @ptrCast(&heading));
        position += 1;
        for (nearby_labels, 0..) |label, i| insert(menu, &position, nearby_base + @as(u32, @intCast(i)), label, null, false);
    }
    if (position == 0) {
        var label: [160]u16 = undefined;
        _ = wide_string.fromUtf8(&label, profiles.data.sidebar.no_servers);
        _ = w32.AppendMenuW(menu, w32.MF_GRAYED, 0, @ptrCast(&label));
    }

    menu_theme.apply(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked < id_profile_base) return null;
    const i: usize = @intCast(picked - id_profile_base);
    if (i < configured.len) return .{ .name = configured[i], .nearby = false };
    if (i - configured.len < recent.len) return .{ .name = recent[i - configured.len], .nearby = false };
    const n = i - configured.len - recent.len;
    if (n < nearby.len) return .{ .name = nearby[n], .nearby = true };
    return null;
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
pub fn newBitmap(size: i32) ?struct { dc: w32.HDC, bitmap: *anyopaque, pixels: [*]u32 } {
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
