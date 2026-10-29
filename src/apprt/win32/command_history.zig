//! Up and Down in cmd.exe recall commands typed in any tab, kept across
//! restarts, as PSReadLine does for PowerShell. cmd forgets its own
//! history when its tab closes, and its console has no way to be given
//! one, so Sharp keeps its own: Enter at cmd's prompt reads the typed
//! line off the screen (cmd's prompt marks where typing starts,
//! termio/cmd_prompt.zig), and Up or Down clears the line with Escape and
//! types the recalled one. Saved beside the config file, one command a
//! line, newest last. Which shells, how many commands and which are
//! never saved come from profiles.zon.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const windows = @import("../../os/main.zig").windows;
const config_file = @import("config_file.zig");
const profiles = @import("profiles.zig");
const win32_input = @import("win32_input.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.command_history);

const file_name = "sharp-cmd-history";
const settings = profiles.data.history;
/// Far more than `settings.size` commands take.
const max_file_size = 4 * 1024 * 1024;

const Entry = struct {
    text: []const u8,
    /// False for commands that look like they hold a secret.
    saved: bool,
};

/// Every tab's commands, oldest first. Only the UI thread touches it.
var entries: std.ArrayList(Entry) = .empty;
var loaded = false;

/// Up, Down and Enter without modifiers, in a pane whose shell keeps no
/// history of its own, at its prompt with no program running. True when
/// the key was taken; Enter is only read, and still goes to cmd.
pub fn key(surface: *Surface, vk: u16, mods: input.Mods) bool {
    if (vk != w32.VK_UP and vk != w32.VK_DOWN and vk != w32.VK_RETURN) return false;
    if (mods.keys().int() != 0) return false;
    if (!keepsNoHistory(surface)) return false;
    const alloc = surface.app.core_app.alloc;
    const typed = typedLine(surface, alloc) orelse return false;
    defer alloc.free(typed);
    if (surface.core_surface.io.commandRunning() orelse true) return false;
    load(alloc);

    switch (vk) {
        w32.VK_RETURN => {
            record(alloc, typed);
            surface.history_back = 0;
            return false;
        },
        w32.VK_UP => {
            if (surface.history_back >= entries.items.len) return true;
            surface.history_back += 1;
        },
        else => {
            if (surface.history_back == 0) return true;
            surface.history_back -= 1;
        },
    }
    const line = if (surface.history_back == 0) "" else entries.items[entries.items.len - surface.history_back].text;
    replaceLine(surface, alloc, line);
    return true;
}

/// Whether the pane's shell is one profiles.zon lists, looked up once its
/// process exists.
fn keepsNoHistory(surface: *Surface) bool {
    if (surface.history_shell) |known| return known;
    const pid = surface.core_surface.io.processId() orelse return false;
    const listed = shellListed(pid);
    surface.history_shell = listed;
    return listed;
}

fn shellListed(pid: u32) bool {
    const kernel32 = windows.exp.kernel32;
    const process = kernel32.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, pid) orelse return false;
    defer _ = kernel32.CloseHandle(process);
    var path: [windows.MAX_PATH * 2:0]u16 = undefined;
    var len: windows.DWORD = path.len;
    if (kernel32.QueryFullProcessImageNameW(process, 0, &path, &len) == windows.FALSE) return false;
    var utf8: [windows.MAX_PATH * 6]u8 = undefined;
    const full = utf8[0 .. std.unicode.utf16LeToUtf8(&utf8, path[0..len]) catch return false];
    const exe = std.fs.path.basenameWindows(full);
    for (settings.shells) |shell| {
        if (std.ascii.eqlIgnoreCase(exe, shell)) return true;
    }
    return false;
}

/// What is typed after the prompt the cursor sits at ("" for nothing),
/// or null when the cursor isn't on the prompt's row or a row its typing
/// wrapped onto. cmd sends no mark when a command starts, so Ghostty's
/// own prompt test would still say "prompt" during its output; the
/// cursor leaving the row is what tells.
fn typedLine(surface: *Surface, alloc: Allocator) ?[:0]const u8 {
    const core = &surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const t = &core.io.terminal;
    if (t.screens.active_key == .alternate) return null;
    const screen: *terminal.Screen = t.screens.active;
    var prompt = screen.cursor.page_pin.*;
    while (prompt.rowAndCell().row.wrap_continuation) prompt = prompt.up(1) orelse return null;
    if (prompt.rowAndCell().row.semantic_prompt == .none) return null;
    prompt.x = 0;
    const typed = screen.pages.highlightSemanticContent(prompt, .input) orelse return alloc.dupeSentinel(u8, "", 0) catch null;
    return screen.selectionString(alloc, .{ .sel = .init(typed.start, typed.end, false) }) catch null;
}

/// Escape clears cmd's line; the text is then typed as characters.
fn replaceLine(surface: *Surface, alloc: Allocator, text: []const u8) void {
    win32_input.writeWin32InputSequence(surface, w32.VK_ESCAPE, 1, 0x1B, 1, 0, 1);
    win32_input.writeWin32InputSequence(surface, w32.VK_ESCAPE, 1, 0x1B, 0, 0, 1);
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch return;
    defer alloc.free(wide);
    for (wide) |unit| win32_input.sendWin32CharEvent(surface, unit);
}

/// Add a submitted command as the newest, dropping an older copy of it.
fn record(alloc: Allocator, typed: []const u8) void {
    const text = std.mem.trim(u8, typed, " \t");
    if (text.len == 0) return;
    for (entries.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.text, text)) continue;
        alloc.free(entry.text);
        _ = entries.orderedRemove(i);
        break;
    }
    const owned = alloc.dupe(u8, text) catch return;
    entries.append(alloc, .{ .text = owned, .saved = !private(text) }) catch {
        alloc.free(owned);
        return;
    };
    dropOldest(alloc);
    save(alloc) catch |err| log.warn("could not save the command history: {}", .{err});
}

fn private(text: []const u8) bool {
    for (settings.private) |word| {
        if (std.ascii.findIgnoreCase(text, word) != null) return true;
    }
    return false;
}

fn dropOldest(alloc: Allocator) void {
    if (entries.items.len <= settings.size) return;
    const extra = entries.items.len - settings.size;
    for (entries.items[0..extra]) |entry| alloc.free(entry.text);
    entries.replaceRangeAssumeCapacity(0, extra, &.{});
}

/// Read the saved commands once. A line that isn't UTF-8 is skipped.
fn load(alloc: Allocator) void {
    if (loaded) return;
    loaded = true;
    const file = config_file.besideConfig(alloc, file_name) catch return;
    defer alloc.free(file);
    const text = std.Io.Dir.cwd().readFileAlloc(global.io(), file, alloc, .limited(max_file_size)) catch |err| {
        if (err != error.FileNotFound) log.warn("could not read the command history: {}", .{err});
        return;
    };
    defer alloc.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) continue;
        const owned = alloc.dupe(u8, line) catch return;
        entries.append(alloc, .{ .text = owned, .saved = true }) catch {
            alloc.free(owned);
            return;
        };
    }
    dropOldest(alloc);
}

fn save(alloc: Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (entries.items) |entry| {
        if (!entry.saved) continue;
        try out.appendSlice(alloc, entry.text);
        try out.append(alloc, '\n');
    }
    const file = try config_file.besideConfig(alloc, file_name);
    defer alloc.free(file);
    try std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = file, .data = out.items });
}
