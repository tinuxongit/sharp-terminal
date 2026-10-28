//! What the settings panel offers, from settings.zon, and how each setting
//! reads from the user's config file. Writing goes through config_file.
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const config_file = @import("config_file.zig");
const menu_theme = @import("menu_theme.zig");
const profiles = @import("profiles.zig");
const SearchField = @import("SearchField.zig");

pub const Choice = struct {
    label: []const u8,
    value: []const u8,
    requires_font: ?[]const u8 = null,
};

pub const Action = enum { edit_file, reload };

pub const Setting = struct {
    label: []const u8,
    description: []const u8,
    key: []const u8 = "",
    choices: []const Choice = &.{},
    /// Offer the installed shell profiles instead of fixed choices.
    profiles: bool = false,
    on: ?[]const u8 = null,
    off: ?[]const u8 = null,
    default_on: bool = false,
    action: ?Action = null,
    button: []const u8 = "",

    pub const Kind = enum { dropdown, toggle, action };

    pub fn kind(self: Setting) Kind {
        if (self.action != null) return .action;
        if (self.on != null) return .toggle;
        return .dropdown;
    }
};

pub const Section = struct {
    title: []const u8,
    settings: []const Setting,
};

pub const Category = struct {
    name: []const u8,
    icon: u16,
    sections: []const Section,
};

pub const Data = struct {
    title: []const u8,
    search_placeholder: []const u8,
    restore_label: []const u8,
    restore_confirm: []const u8,
    no_results: []const u8,
    categories: []const Category,
};

pub const data: Data = @import("settings.zon");

comptime {
    @setEvalBranchQuota(10_000);
    for (data.categories) |category| {
        for (category.sections) |section| {
            for (section.settings) |s| {
                const where = "settings.zon: '" ++ s.label ++ "' ";
                const kinds = @as(u8, @intFromBool(s.action != null)) + @intFromBool(s.on != null or s.off != null) + @intFromBool(s.choices.len > 0 or s.profiles);
                if (kinds != 1) @compileError(where ++ "needs exactly one of choices, profiles, on/off or action");
                if (s.profiles and s.choices.len > 0) @compileError(where ++ "can't have both choices and profiles");
                if ((s.on == null) != (s.off == null)) @compileError(where ++ "needs both on and off");
                if (s.action == null and s.key.len == 0) @compileError(where ++ "needs a key");
                if (s.action != null and s.button.len == 0) @compileError(where ++ "needs a button label");
            }
        }
    }
}

/// Names one setting in `data`.
pub const Ref = struct {
    category: usize,
    section: usize,
    setting: usize,

    pub fn get(self: Ref) Setting {
        return data.categories[self.category].sections[self.section].settings[self.setting];
    }
};

/// An empty `on` or `off` stands for the key being absent, so any other
/// value counts as the opposite state.
pub fn toggleIsOn(setting: Setting, config_text: []const u8) bool {
    const v = config_file.currentValue(config_text, setting.key) orelse return setting.default_on;
    const on = setting.on.?;
    return !config_file.sameValue(v, setting.off.?) and (on.len == 0 or config_file.sameValue(v, on));
}

/// What a dropdown shows: the label of the current choice, or the raw
/// value when the file holds something the panel doesn't offer.
pub fn currentLabel(setting: Setting, config_text: []const u8, list: *const profiles.List) []const u8 {
    const v = config_file.currentValue(config_text, setting.key);
    if (setting.profiles) {
        const i = list.selected(v) orelse return v orelse "";
        return list.name(i);
    }
    for (setting.choices) |choice| {
        const selected = if (v) |value| config_file.sameValue(value, choice.value) else choice.value.len == 0;
        if (selected) return choice.label;
    }
    return v orelse "";
}

/// Whether a search query matches a setting's label or description.
pub fn matches(setting: Setting, query: []const u8) bool {
    if (query.len == 0) return true;
    return SearchField.matches(setting.label, query) or SearchField.matches(setting.description, query);
}

/// Show a dropdown's choices as a menu with its top-left corner at
/// `point` (screen pixels). The value picked is copied into `out`, since
/// profile commands live in a list that ends with this call.
pub fn pickChoice(owner: w32.HWND, point: w32.POINT, setting: Setting, config_text: []const u8, dark: bool, out: []u8) ?[]const u8 {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    const hdc = w32.GetDC(owner) orelse return null;
    defer _ = w32.ReleaseDC(owner, hdc);

    const list = profiles.detect();
    const current = currentLabel(setting, config_text, &list);
    const count = if (setting.profiles) list.len else setting.choices.len;
    for (0..count) |i| {
        const label = if (setting.profiles) list.name(i) else setting.choices[i].label;
        if (!setting.profiles and !fontAvailable(hdc, setting.choices[i])) continue;
        const checked = std.mem.eql(u8, label, current);
        var buf: [128]u16 = undefined;
        _ = wide_string.fromUtf8(&buf, label);
        _ = w32.AppendMenuW(menu, if (checked) w32.MF_CHECKED else w32.MF_STRING, i + 1, @ptrCast(&buf));
    }
    menu_theme.apply(dark);
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null);
    if (picked <= 0) return null;
    const i: usize = @as(usize, @intCast(picked)) - 1;
    const value = if (!setting.profiles)
        setting.choices[i].value
    else if (list.items[i].default)
        // The default shell is what an absent `command` runs.
        ""
    else
        list.command(i);
    if (value.len > out.len) return null;
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}

/// Hide choices whose font is missing: Windows would silently fall back
/// to another font.
fn fontAvailable(hdc: w32.HDC, choice: Choice) bool {
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
