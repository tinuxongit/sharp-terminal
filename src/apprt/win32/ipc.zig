//! `sharp +new-tab` and `sharp +new-window` on Windows, as Windows
//! Terminal's `wt -w 0 nt`: the command finds a running Sharp and asks it,
//! through WM_COPYDATA to its message window, to open a tab or window with
//! the arguments given (-e, --command, --working-directory, --title). With
//! no Sharp running, or only one Windows won't let it talk to (an elevated
//! one), it starts Sharp with those arguments instead.
const std = @import("std");
const w32 = @import("win32.zig");
const command_line = @import("command_line.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.ipc);

/// Marks Sharp's WM_COPYDATA, and which action it carries.
const magic: usize = 0x53480000;
pub const Kind = enum(u8) { new_tab = 1, new_window = 2 };

/// Ask a running Sharp to open `kind` with `arguments`, or start one.
pub fn send(alloc: std.mem.Allocator, msg_class: [*:0]const u16, kind: Kind, arguments: ?[]const [:0]const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    for (arguments orelse &.{}) |arg| {
        try payload.appendSlice(alloc, arg);
        try payload.append(alloc, 0);
    }
    var data: COPYDATASTRUCT = .{
        .dwData = magic | @intFromEnum(kind),
        .cbData = @intCast(payload.items.len),
        .lpData = if (payload.items.len > 0) payload.items.ptr else null,
    };
    var window: ?w32.HWND = null;
    while (true) {
        window = FindWindowExW(w32.HWND_MESSAGE, window, msg_class, null);
        const hwnd = window orelse break;
        var pid: u32 = 0;
        _ = w32.GetWindowThreadProcessId(hwnd, &pid);
        // Let it bring its window to the front, as the user asked for it.
        _ = AllowSetForegroundWindow(pid);
        var result: usize = 0;
        if (SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, @bitCast(@intFromPtr(&data)), SMTO_ABORTIFHUNG, 5000, &result) != 0 and result == 1)
            return;
    }
    try startNew(alloc, arguments);
}

fn startNew(alloc: std.mem.Allocator, arguments: ?[]const [:0]const u8) !void {
    var exe: [1024]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return error.IPCFailed;
    var args: std.Io.Writer.Allocating = .init(alloc);
    defer args.deinit();
    for (arguments orelse &.{}) |arg| {
        try args.writer.writeByte(' ');
        try command_line.quote(&args.writer, "", arg);
    }
    const args_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, args.written());
    defer alloc.free(args_w);
    var line: std.ArrayList(u16) = .empty;
    defer line.deinit(alloc);
    try line.append(alloc, '"');
    try line.appendSlice(alloc, exe[0..exe_len]);
    try line.append(alloc, '"');
    try line.appendSlice(alloc, args_w);
    try line.append(alloc, 0);
    var startup: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    var info: PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(null, @ptrCast(line.items.ptr), null, null, windows.FALSE, 0, null, null, &startup, &info) == windows.FALSE) return error.IPCFailed;
    _ = windows.exp.kernel32.CloseHandle(info.hThread);
    _ = windows.exp.kernel32.CloseHandle(info.hProcess);
}

/// What a tab or window opened through IPC overrides, as GTK reads the
/// same arguments (apprt/gtk/class/Overrides.zig).
pub const Overrides = struct {
    command: ?configpkg.Command = null,
    working_directory: ?[]const u8 = null,
    title: ?[:0]const u8 = null,
};

/// A WM_COPYDATA Sharp's IPC sent: its kind and arguments, which live in
/// `arena`. Null for anyone else's.
pub fn receive(arena: std.mem.Allocator, lparam: isize) ?struct { kind: Kind, overrides: Overrides } {
    const data: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (data.dwData & 0xFFFF0000 != magic) return null;
    const kind = std.enums.fromInt(Kind, @as(u8, @truncate(data.dwData))) orelse return null;
    const bytes: []const u8 = if (data.lpData) |p| p[0..data.cbData] else &.{};

    var overrides: Overrides = .{};
    var e_args: std.ArrayList([:0]const u8) = .empty;
    var e_seen = false;
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        if (e_seen) {
            e_args.append(arena, arena.dupeSentinel(u8, arg, 0) catch return null) catch return null;
        } else if (std.mem.eql(u8, arg, "-e")) {
            e_seen = true;
        } else if (std.mem.startsWith(u8, arg, "--command=")) {
            var cmd: configpkg.Command = undefined;
            cmd.parseCLI(arena, arg["--command=".len..]) catch continue;
            overrides.command = cmd;
        } else if (std.mem.startsWith(u8, arg, "--working-directory=")) {
            overrides.working_directory = arena.dupe(u8, std.mem.trim(u8, arg["--working-directory=".len..], &std.ascii.whitespace)) catch return null;
        } else if (std.mem.startsWith(u8, arg, "--title=")) {
            overrides.title = arena.dupeSentinel(u8, arg["--title=".len..], 0) catch return null;
        }
    }
    if (e_args.items.len > 0) overrides.command = .{ .direct = e_args.items };
    return .{ .kind = kind, .overrides = overrides };
}

pub const WM_COPYDATA: u32 = 0x004A;
const SMTO_ABORTIFHUNG: u32 = 0x0002;

const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: u32,
    lpData: ?[*]const u8,
};

const windows = @import("../../os/main.zig").windows;
const STARTUPINFOW = windows.STARTUPINFOW;
const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;

extern "user32" fn FindWindowExW(parent: ?w32.HWND, after: ?w32.HWND, class: [*:0]const u16, title: ?[*:0]const u16) callconv(.winapi) ?w32.HWND;
extern "user32" fn SendMessageTimeoutW(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize, flags: u32, timeout: u32, result: *usize) callconv(.winapi) isize;
extern "user32" fn AllowSetForegroundWindow(pid: u32) callconv(.winapi) i32;
