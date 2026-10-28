//! Showing a folder in Explorer (`sharp:open_folder`), as Windows
//! Terminal's openCWD does.
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");

const log = std.log.scoped(.shell_open);

/// Open `path` in Explorer, if it is a folder that exists. The path comes
/// from the shell (OSC 7), so anything else, such as a program, is never
/// handed to the shell to open.
pub fn folder(path: []const u8) void {
    var wide: [1024:0]u16 = undefined;
    if (path.len == 0 or path.len >= wide.len) return;
    const len = wide_string.fromUtf8(&wide, path);
    wide[len] = 0;
    const attributes = w32.GetFileAttributesW(&wide);
    const directory = 0x10;
    if (attributes == 0xFFFFFFFF or attributes & directory == 0) {
        log.info("not a folder, not opened", .{});
        return;
    }
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("explore"), &wide, null, null, w32.SW_SHOW);
}
