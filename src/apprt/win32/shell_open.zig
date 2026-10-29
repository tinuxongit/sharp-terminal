//! Opening folders and files through the shell: the tab's folder in
//! Explorer (`sharp:open_folder`), as Windows Terminal's openCWD does, and
//! the local files and folders that links printed in the terminal point to.
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");

const log = std.log.scoped(.shell_open);

const open_files: struct {
    viewed: []const []const u8,
    confirm_title: []const u8,
    confirm_text: []const u8,
} = @import("open_files.zon");

const directory = 0x10;
const missing = 0xFFFFFFFF;

/// Open `path` in Explorer, if it is a folder that exists. The path comes
/// from the shell (OSC 7), so anything else, such as a program, is never
/// handed to the shell to open.
pub fn folder(path: []const u8) void {
    var wide: [1024:0]u16 = undefined;
    const target = toWide(&wide, path) orelse return;
    const attributes = w32.GetFileAttributesW(target);
    if (attributes == missing or attributes & directory == 0) {
        log.info("not a folder, not opened", .{});
        return;
    }
    explore(target);
}

/// Open the file or folder a link printed in the terminal points to
/// (`UntrustedUrl.localPath`). A folder opens in Explorer and a file its
/// app only shows (`open_files.zon`) opens in that app. Any other file asks
/// first, since on Windows opening a file can run it. A path that doesn't
/// exist opens nothing, so Windows never searches for a program by that
/// name.
pub fn linked(path: []const u8) void {
    var wide: [1024:0]u16 = undefined;
    const target = toWide(&wide, path) orelse return;
    const attributes = w32.GetFileAttributesW(target);
    if (attributes == missing) {
        log.info("linked path doesn't exist, not opened", .{});
        return;
    }
    if (attributes & directory != 0) return explore(target);
    if (!isViewed(path) and !confirmed(path)) return;
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), target, null, null, w32.SW_SHOW);
}

fn explore(target: [*:0]const u16) void {
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("explore"), target, null, null, w32.SW_SHOW);
}

/// Null when `path` doesn't fit, since a cut path names another file.
fn toWide(wide: *[1024:0]u16, path: []const u8) ?[*:0]const u16 {
    // UTF-8 never needs more UTF-16 units than it has bytes.
    if (path.len == 0 or path.len >= wide.len) return null;
    const len = wide_string.fromUtf8(wide, path);
    wide[len] = 0;
    return wide;
}

fn isViewed(path: []const u8) bool {
    // Windows drops a name's trailing dots and spaces: "run.exe." is run.exe.
    const name = std.mem.trimEnd(u8, std.fs.path.basenameWindows(path), ". ");
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    for (open_files.viewed) |extension| {
        if (std.ascii.eqlIgnoreCase(name[dot..], extension)) return true;
    }
    return false;
}

fn confirmed(path: []const u8) bool {
    var text: [2048:0]u16 = undefined;
    var title: [64:0]u16 = undefined;
    const prompt_len = open_files.confirm_text.len + path.len;
    if (prompt_len >= text.len or open_files.confirm_title.len >= title.len) return false;
    var len = wide_string.fromUtf8(&text, open_files.confirm_text);
    len += wide_string.fromUtf8(text[len..], path);
    text[len] = 0;
    title[wide_string.fromUtf8(&title, open_files.confirm_title)] = 0;
    return w32.MessageBoxW(null, &text, &title, w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2) == w32.IDOK;
}
