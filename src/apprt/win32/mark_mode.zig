//! Selecting with the keyboard, as Windows Terminal's mark mode does
//! (`sharp:mark_mode`): a selection starts at the cursor, arrows and
//! Page Up/Down, Home and End extend it, Enter copies it and Escape
//! leaves. `sharp:block_selection` turns any selection into a rectangle,
//! or back.
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.mark_mode);

/// Start selecting at the cursor.
pub fn start(self: *Surface) void {
    const core = &self.core_surface;
    {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const screen: *terminal.Screen = core.io.terminal.screens.active;
        const pin = screen.cursor.page_pin.*;
        screen.select(terminal.Selection.init(pin, pin, false)) catch |err| {
            log.warn("could not start a selection: {}", .{err});
            return;
        };
    }
    self.marking = true;
    core.renderer_thread.wakeup.notify() catch {};
}

/// A key while selecting: true when mark mode took it.
pub fn key(self: *Surface, vk: u16) bool {
    const direction: ?input.Binding.Action.AdjustSelection = switch (vk) {
        w32.VK_LEFT => .left,
        w32.VK_RIGHT => .right,
        w32.VK_UP => .up,
        w32.VK_DOWN => .down,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_HOME => .home,
        w32.VK_END => .end,
        else => null,
    };
    if (direction) |d| {
        perform(self, .{ .adjust_selection = d });
        return true;
    }
    switch (vk) {
        w32.VK_RETURN => {
            perform(self, .{ .copy_to_clipboard = .mixed });
            stop(self);
        },
        w32.VK_ESCAPE => stop(self),
        // Modifiers pass, so Ctrl+Shift+... bindings still work.
        w32.VK_SHIFT, w32.VK_CONTROL, w32.VK_MENU => return false,
        // Any other key ends mark mode but goes on as usual, keeping the
        // selection for a binding such as sharp:block_selection.
        else => {
            self.marking = false;
            return false;
        },
    }
    return true;
}

fn stop(self: *Surface) void {
    self.marking = false;
    const core = &self.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    core.io.terminal.screens.active.clearSelection();
}

/// Turn the selection into a rectangle, or back into lines.
pub fn toggleBlock(self: *Surface) void {
    const core = &self.core_surface;
    {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const screen: *terminal.Screen = core.io.terminal.screens.active;
        // Through select, so the renderer redraws the rows it covers.
        var next = screen.selection orelse return;
        next.rectangle = !next.rectangle;
        screen.select(next) catch |err| log.warn("could not change the selection: {}", .{err});
    }
    core.renderer_thread.wakeup.notify() catch {};
}

fn perform(self: *Surface, action: input.Binding.Action) void {
    _ = self.core_surface.performBindingAction(action) catch |err| log.warn("mark mode action failed: {}", .{err});
}
