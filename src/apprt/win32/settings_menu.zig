//! The gear button's menu. Its entries come from settings_menu.zon; this
//! file builds the Win32 menu, marks the current values and reports what
//! was picked. Writing the change is the caller's job (see config_file).
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const config_file = @import("config_file.zig");

const log = std.log.scoped(.win32);

pub const Choice = struct {
    label: []const u8,
    value: []const u8,
    requires_program: ?[]const u8 = null,
    requires_font: ?[]const u8 = null,
};

pub const Entry = struct {
    label: []const u8,
    key: []const u8,
    choices: []const Choice = &.{},
    /// Set for toggles instead of choices.
    on: ?[]const u8 = null,
    off: ?[]const u8 = null,
    default_on: bool = false,
};

pub const Data = struct {
    entries: []const Entry,
    edit_file_label: []const u8,
    reload_label: []const u8,
};

const data: Data = @import("settings_menu.zon");

comptime {
    for (data.entries) |entry| {
        const toggle = entry.on != null or entry.off != null;
        if (toggle == (entry.choices.len > 0)) @compileError("settings_menu.zon: '" ++ entry.label ++ "' needs either choices or on/off values");
        if (toggle and (entry.on == null or entry.off == null)) @compileError("settings_menu.zon: toggle '" ++ entry.label ++ "' needs both on and off");
        if (entry.choices.len >= toggle_slot) @compileError("settings_menu.zon: too many choices in '" ++ entry.label ++ "'");
    }
}

pub const Pick = union(enum) {
    set: struct { key: []const u8, value: []const u8 },
    edit_file,
    reload,
};

const id_edit_file = 1;
const id_reload = 2;
const id_base = 1000;
const ids_per_entry = 100;
const toggle_slot = ids_per_entry - 1;

/// Show the menu with its top-right corner at `point` (screen pixels) and
/// return what the user picked, if anything.
pub fn show(alloc: std.mem.Allocator, owner: w32.HWND, point: w32.POINT, dark: bool) ?Pick {
    const contents = config_file.read(alloc) catch |err| blk: {
        log.warn("unable to read config file for the settings menu: {}", .{err});
        break :blk alloc.alloc(u8, 0) catch return null;
    };
    defer alloc.free(contents);

    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);

    const hdc = w32.GetDC(owner) orelse return null;
    defer _ = w32.ReleaseDC(owner, hdc);

    for (data.entries, 0..) |entry, e| {
        const base = id_base + e * ids_per_entry;
        const current = config_file.currentValue(contents, entry.key);
        if (entry.on != null) {
            append(menu, if (toggleIsOn(entry, current)) w32.MF_CHECKED else w32.MF_STRING, base + toggle_slot, entry.label);
            continue;
        }

        const sub = w32.CreatePopupMenu() orelse continue;
        for (entry.choices, 0..) |choice, c| {
            if (!available(hdc, choice)) continue;
            const checked = if (current) |v| config_file.sameValue(v, choice.value) else choice.value.len == 0;
            append(sub, if (checked) w32.MF_CHECKED else w32.MF_STRING, base + c, choice.label);
        }
        // The parent menu owns and destroys the submenu.
        append(menu, w32.MF_POPUP, @intFromPtr(sub), entry.label);
    }
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    append(menu, w32.MF_STRING, id_edit_file, data.edit_file_label);
    append(menu, w32.MF_STRING, id_reload, data.reload_label);

    applyMenuTheme(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_RIGHTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked <= 0) return null;
    const id: usize = @intCast(picked);
    return switch (id) {
        id_edit_file => .edit_file,
        id_reload => .reload,
        else => pick: {
            if (id < id_base) break :pick null;
            const e = (id - id_base) / ids_per_entry;
            const slot = (id - id_base) % ids_per_entry;
            if (e >= data.entries.len) break :pick null;
            const entry = data.entries[e];
            if (slot == toggle_slot) {
                const is_on = toggleIsOn(entry, config_file.currentValue(contents, entry.key));
                break :pick .{ .set = .{ .key = entry.key, .value = if (is_on) entry.off.? else entry.on.? } };
            }
            if (slot >= entry.choices.len) break :pick null;
            break :pick .{ .set = .{ .key = entry.key, .value = entry.choices[slot].value } };
        },
    };
}

/// An empty `on` or `off` stands for the key being absent, so any other
/// value counts as the opposite state.
fn toggleIsOn(entry: Entry, current: ?[]const u8) bool {
    const v = current orelse return entry.default_on;
    const on = entry.on.?;
    return !config_file.sameValue(v, entry.off.?) and (on.len == 0 or config_file.sameValue(v, on));
}

fn append(menu: w32.HMENU, flags: u32, id: usize, label: []const u8) void {
    var buf: [128]u16 = undefined;
    _ = wide_string.fromUtf8(&buf, label);
    _ = w32.AppendMenuW(menu, flags, id, @ptrCast(&buf));
}

/// Hide choices whose program or font is missing: picking them would
/// leave new tabs without a shell, or silently fall back to another font.
fn available(hdc: w32.HDC, choice: Choice) bool {
    if (choice.requires_program) |program| {
        var name: [260]u16 = undefined;
        _ = wide_string.fromUtf8(&name, program);
        const found = if (std.fs.path.isAbsolute(program))
            w32.GetFileAttributesW(@ptrCast(&name)) != w32.INVALID_FILE_ATTRIBUTES
        else
            w32.SearchPathW(null, @ptrCast(&name), null, 0, null, null) != 0;
        if (!found) return false;
    }
    if (choice.requires_font) |font| {
        var face: [32]u16 = undefined;
        _ = wide_string.fromUtf8(&face, font);
        const probe = w32.CreateFontW(-12, 0, 0, 0, w32.FW_NORMAL, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, 0, 0, @ptrCast(&face)) orelse return false;
        defer _ = w32.DeleteObject(probe);
        const old = w32.SelectObject(hdc, probe);
        defer _ = w32.SelectObject(hdc, old);
        // Windows substitutes another font for a missing one, so compare
        // the face it actually picked.
        var picked: [32]u16 = @splat(0);
        if (w32.GetTextFaceW(hdc, picked.len - 1, &picked) <= 0) return false;
        if (!sameFace(std.mem.sliceTo(&face, 0), std.mem.sliceTo(&picked, 0))) return false;
    }
    return true;
}

/// Font names compare without case, as Windows matches them.
fn sameFace(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x < 0x80) std.ascii.toLower(@intCast(x)) else x;
        const ly = if (y < 0x80) std.ascii.toLower(@intCast(y)) else y;
        if (lx != ly) return false;
    }
    return true;
}

/// Popup menus follow the app-wide theme set through uxtheme's unnamed
/// SetPreferredAppMode export (ordinal 135), the same one Explorer and
/// Notepad use. Match the strip: dark menus on a dark terminal.
pub fn applyMenuTheme(dark: bool) void {
    const uxtheme = w32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll")) orelse return;
    const SetPreferredAppMode = *const fn (c_int) callconv(.winapi) c_int;
    const FlushMenuThemes = *const fn () callconv(.winapi) void;
    const set_mode: SetPreferredAppMode = @ptrCast(w32.GetProcAddress(uxtheme, @ptrFromInt(135)) orelse return);
    const flush: FlushMenuThemes = @ptrCast(w32.GetProcAddress(uxtheme, @ptrFromInt(136)) orelse return);
    // 2 = ForceDark, 3 = ForceLight.
    _ = set_mode(if (dark) 2 else 3);
    flush();
}
