//! Where shell prompts start in a pane's history, for the ticks on its
//! scrollbar, as Windows Terminal's showMarksOnScrollbar shows them. The
//! prompts are the shell integration's marks (OSC 133), which Ghostty's
//! jump_to_prompt also follows.
const std = @import("std");
const global = @import("../../global.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

/// A pane's prompts, as rows from the top of its history.
pub const Marks = struct {
    rows: [max]u32 = undefined,
    len: usize = 0,
    /// The history's length when they were counted, and when.
    total: usize = 0,
    counted_ms: u64 = 0,

    /// More would be ticks closer than a pixel on any screen.
    pub const max = 512;

    pub fn slice(self: *const Marks) []const u32 {
        return self.rows[0..self.len];
    }
};

/// Count again when the history's length changed, at most four times a
/// second: walking a long history costs time, and output can change it
/// every frame. Returns whether they were counted again.
pub fn refresh(marks: *Marks, core: *CoreSurface, total: usize, now_ms: u64) bool {
    if (total == marks.total or now_ms -% marks.counted_ms < 250) return false;
    marks.total = total;
    marks.counted_ms = now_ms;

    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const pages = &core.io.terminal.screens.active.pages;
    var it = pages.promptIterator(.right_down, .{ .screen = .{} }, null);
    var len: usize = 0;
    while (it.next()) |pin| {
        if (len == Marks.max) break;
        const point = pages.pointFromPin(.screen, pin) orelse continue;
        marks.rows[len] = @intCast(point.screen.y);
        len += 1;
    }
    marks.len = len;
    return true;
}
