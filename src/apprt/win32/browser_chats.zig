const std = @import("std");
const w32 = @import("win32.zig");
const process_tree = @import("process_tree.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const browser_dock = @import("browser_dock.zig");

pub const Owner = u64;

const outside: Owner = 1 << 63;
const max_ancestors = 16;

pub const Chat = struct {
    ancestors: [max_ancestors]u32 = undefined,
    len: usize = 0,
    claude: u32 = 0,

    pub fn ofClient(pipe: w32.HANDLE) Chat {
        var chat: Chat = .{};
        var pid: u32 = 0;
        if (w32.GetNamedPipeClientProcessId(pipe, &pid) == 0) return chat;
        const procs = std.heap.smp_allocator.create(process_tree.Processes) catch return chat;
        defer std.heap.smp_allocator.destroy(procs);
        procs.* = process_tree.Processes.take();
        var current = pid;
        while (chat.len < max_ancestors) {
            const p = procs.find(current) orelse break;
            chat.ancestors[chat.len] = p.pid;
            chat.len += 1;
            if (p.program == .claude and chat.claude == 0) chat.claude = p.pid;
            if (p.parent == 0 or p.parent == p.pid) break;
            current = p.parent;
        }
        return chat;
    }

    fn processKey(self: *const Chat) u32 {
        if (self.claude != 0) return self.claude;
        return if (self.len > 1) self.ancestors[1] else 0;
    }
};

pub const Placement = struct {
    window: *Window,
    owner: Owner,
    in_sight: bool,
};

pub fn place(app: *App, chat: *const Chat) ?Placement {
    if (paneOf(app, chat)) |surface| {
        const window = surface.parent_window;
        if (browser_dock.enabled(window)) return .{
            .window = window,
            .owner = surface.pane_id,
            .in_sight = paneOwner(window) == surface.pane_id,
        };
        return .{ .window = shownWindow(app) orelse return null, .owner = surface.pane_id, .in_sight = true };
    }
    return .{ .window = shownWindow(app) orelse return null, .owner = outside | chat.processKey(), .in_sight = true };
}

fn paneOf(app: *App, chat: *const Chat) ?*Surface {
    for (chat.ancestors[0..chat.len]) |pid| {
        for (app.windows.items) |window| {
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    const surface = entry.view;
                    if (!surface.core_surface_ready) continue;
                    if (surface.core_surface.io.processId() == pid) return surface;
                }
            }
        }
    }
    return null;
}

fn shownWindow(app: *App) ?*Window {
    for (app.windows.items) |w| if (w.browser != null and w.browser_shown) return w;
    for (app.windows.items) |w| if (w.browser != null) return w;
    for (app.windows.items) |w| if (browser_dock.enabled(w)) return w;
    return null;
}

pub fn paneOwner(window: *Window) Owner {
    const surface = window.getActiveSurface() orelse return 0;
    return surface.pane_id;
}

pub fn alive(app: *App, owner: Owner) bool {
    if (owner & outside != 0) return processRunning(@truncate(owner & ~outside));
    for (app.windows.items) |window| {
        for (0..window.tab_count) |i| {
            var it = window.tab_trees[i].iterator();
            while (it.next()) |entry| if (entry.view.pane_id == owner) return true;
        }
    }
    return false;
}

fn processRunning(pid: u32) bool {
    if (pid == 0) return false;
    const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = w32.CloseHandle(process);
    var code: u32 = 0;
    return w32.GetExitCodeProcess(process, &code) != 0 and code == w32.STILL_ACTIVE;
}
