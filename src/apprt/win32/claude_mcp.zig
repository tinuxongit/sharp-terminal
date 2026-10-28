//! Adds Sharp's MCP server to Claude Code when Settings > AI > Tools >
//! Browser is switched on, and removes it when switched off, through
//! Claude Code's own `claude mcp` commands. Nothing else in Claude Code's
//! configuration is touched, and only that switch touches it.
const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const profiles = @import("profiles.zig");
const wide_string = @import("wide_string.zig");
const browser_tools = @import("browser_tools.zig");

const windows = internal_os.windows;
const kernel32 = windows.exp.kernel32;
const log = std.log.scoped(.win32);

/// Register or unregister in the background; `claude` takes seconds.
pub fn register(on: bool) void {
    const thread = std.Thread.spawn(.{}, run, .{on}) catch |err| {
        log.warn("failed to update Claude Code's MCP servers: {}", .{err});
        return;
    };
    thread.detach();
}

fn run(on: bool) void {
    if (!profiles.programExists("claude.exe")) return;
    const name = browser_tools.data.server_name;
    // Removing first replaces a registration that points at an older copy.
    runHidden("claude.exe mcp remove --scope user " ++ name);
    if (!on) return;
    var path: [1024]u16 = undefined;
    const len = w32.GetModuleFileNameW(null, &path, path.len);
    if (len == 0 or len >= path.len) return;
    const dir_end = (std.mem.lastIndexOfScalar(u16, path[0..len], '\\') orelse return) + 1;
    var dir: [2048]u8 = undefined;
    const dir_len = wide_string.toUtf8(&dir, path[0..dir_end]);
    var command: [2300]u8 = undefined;
    const line = std.fmt.bufPrint(&command, "claude.exe mcp add --scope user {s} -- \"{s}sharp-mcp.exe\"", .{ name, dir[0..dir_len] }) catch return;
    runHidden(line);
}

/// Run a command line with no console window and wait up to a minute.
fn runHidden(command_line: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, command_line) catch return;
    defer std.heap.smp_allocator.free(wide);
    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var info: windows.PROCESS_INFORMATION = undefined;
    const create_no_window = 0x08000000;
    if (kernel32.CreateProcessW(null, wide.ptr, null, null, windows.FALSE, create_no_window, null, null, &startup, &info) == windows.FALSE) {
        log.warn("could not run: {s}", .{command_line});
        return;
    }
    defer _ = kernel32.CloseHandle(info.hProcess);
    _ = kernel32.CloseHandle(info.hThread);
    _ = w32.WaitForSingleObject(info.hProcess, 60_000);
}
