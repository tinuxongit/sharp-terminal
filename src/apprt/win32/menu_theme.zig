//! Native popup menus follow the app-wide theme set through uxtheme's
//! unnamed SetPreferredAppMode export (ordinal 135), the same one Explorer
//! and Notepad use. Sharp matches its menus to the terminal's colors.
const std = @import("std");
const w32 = @import("win32.zig");

pub fn apply(dark: bool) void {
    // From System32 only: a uxtheme.dll planted beside sharp.exe (say, in
    // the Downloads folder it was unzipped to) must not be loaded.
    const uxtheme = w32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll"), null, w32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return;
    const SetPreferredAppMode = *const fn (c_int) callconv(.winapi) c_int;
    const FlushMenuThemes = *const fn () callconv(.winapi) void;
    const set_mode: SetPreferredAppMode = @ptrCast(w32.GetProcAddress(uxtheme, @ptrFromInt(135)) orelse return);
    const flush: FlushMenuThemes = @ptrCast(w32.GetProcAddress(uxtheme, @ptrFromInt(136)) orelse return);
    // 2 = ForceDark, 3 = ForceLight.
    _ = set_mode(if (dark) 2 else 3);
    flush();
}
