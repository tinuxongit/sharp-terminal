//! Starting Sharp when the user signs in (`start-at-login`), as Windows
//! Terminal's startOnUserLogin: a value under the user's Run key, the
//! place Settings > Apps > Startup lists and switches.
const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.startup);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const run_key = L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const value_name = L("Sharp Terminal");

/// Add this copy of Sharp to the programs Windows starts at sign-in, or
/// remove it.
pub fn set(on: bool) void {
    var key: w32.HKEY = undefined;
    if (w32.RegCreateKeyExW(w32.HKEY_CURRENT_USER, run_key, 0, null, 0, w32.KEY_SET_VALUE, null, &key, null) != w32.ERROR_SUCCESS) {
        log.warn("could not open the startup programs", .{});
        return;
    }
    defer _ = w32.RegCloseKey(key);
    if (!on) {
        _ = w32.RegDeleteValueW(key, value_name);
        return;
    }
    var line: [1100]u16 = undefined;
    line[0] = '"';
    const len = w32.GetModuleFileNameW(null, line[1..].ptr, line.len - 3);
    if (len == 0 or len >= line.len - 3) return;
    line[len + 1] = '"';
    line[len + 2] = 0;
    const bytes = std.mem.sliceAsBytes(line[0 .. len + 3]);
    if (w32.RegSetValueExW(key, value_name, 0, w32.REG_SZ, bytes.ptr, @intCast(bytes.len)) != w32.ERROR_SUCCESS)
        log.warn("could not add Sharp to the startup programs", .{});
}
