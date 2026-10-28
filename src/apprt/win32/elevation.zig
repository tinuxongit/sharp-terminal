//! Administrator tabs, as Windows Terminal opens them. An unelevated
//! process can't start an elevated console, so a profile opened as
//! administrator (Ctrl+click in a profile menu) opens in a new Sharp run as
//! administrator, after Windows asks. That Sharp marks itself with a
//! shield and "Administrator:" in its title, and leaves the session,
//! updates and the default terminal to the unelevated one.
const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.elevation);

var cached: ?bool = null;

/// Whether this Sharp runs as administrator.
pub fn active() bool {
    if (cached) |v| return v;
    var token: w32.HANDLE = undefined;
    const elevated = blk: {
        if (w32.OpenProcessToken(w32.GetCurrentProcess(), w32.TOKEN_QUERY, &token) == 0) break :blk false;
        defer _ = w32.CloseHandle(token);
        var value: u32 = 0;
        var size: u32 = 0;
        const token_elevation = 20;
        if (GetTokenInformation(token, token_elevation, &value, @sizeOf(u32), &size) == 0) break :blk false;
        break :blk value != 0;
    };
    cached = elevated;
    return elevated;
}

/// Whether a profile picked from a menu should open as administrator:
/// Ctrl was held, as in Windows Terminal (Shift opens a new window).
pub fn requested() bool {
    return w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
}

/// Open `command` (a profile's, as Ghostty's `command` setting reads it)
/// in a new Sharp run as administrator, in `folder` when given.
pub fn open(command: []const u8, folder: ?[]const u8) void {
    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(std.heap.smp_allocator);
    const alloc = std.heap.smp_allocator;
    appendArg(alloc, &params, "--command=", command) catch return;
    if (folder) |dir| {
        params.append(alloc, ' ') catch return;
        appendArg(alloc, &params, "--working-directory=", dir) catch return;
    }

    var exe: [1024:0]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return;
    exe[exe_len] = 0;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, params.items) catch return;
    defer alloc.free(wide);
    // Windows asks for consent; saying no is not an error worth a dialog.
    const result = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("runas"), &exe, wide.ptr, null, w32.SW_SHOW);
    if (result <= 32) log.info("not opened as administrator: {d}", .{result});
}

/// One argument as Windows' command-line parser splits them: quoted, with
/// backslashes before a quote doubled and the quote escaped.
fn appendArg(alloc: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    try out.appendSlice(alloc, prefix);
    var backslashes: usize = 0;
    for (value) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == '"') {
            try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
        } else try out.appendNTimes(alloc, '\\', backslashes);
        backslashes = 0;
        try out.append(alloc, c);
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

extern "advapi32" fn GetTokenInformation(token: w32.HANDLE, class: u32, info: *anyopaque, len: u32, ret_len: *u32) callconv(.winapi) i32;
