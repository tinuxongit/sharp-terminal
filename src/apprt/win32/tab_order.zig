//! Ctrl+Tab in the order tabs were last used, when `tab-switch-order` is
//! `recent`, as Windows Terminal's tabSwitcherMode "mru". While Ctrl is
//! held each Tab goes one tab further back; releasing Ctrl ends the round
//! and makes the tab reached the most recent.
const std = @import("std");
const Window = @import("Window.zig");

/// One window's tabs, most recently used first, by their first pane.
pub const Recent = struct {
    keys: [Window.MAX_TABS]usize = undefined,
    len: usize = 0,
    /// The order frozen for a round of Ctrl+Tab, and where it is.
    round: ?struct { keys: [Window.MAX_TABS]usize, len: usize, at: usize } = null,

    /// Tab `key` became active, outside a round.
    pub fn used(self: *Recent, key: usize) void {
        if (self.round != null) return;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.keys[i] == key) break;
        }
        if (i == self.len) {
            if (self.len == self.keys.len) i -= 1 else self.len += 1;
        }
        std.mem.copyBackwards(usize, self.keys[1 .. i + 1], self.keys[0..i]);
        self.keys[0] = key;
    }

    /// The tab one step further back (or forward) in the round, which
    /// starts at the first step.
    pub fn step(self: *Recent, window: *Window, backwards: bool) ?usize {
        if (self.round == null) {
            var round: @TypeOf(self.round.?) = .{ .keys = undefined, .len = 0, .at = 0 };
            // Tabs closed since stay out; tabs never used go last.
            for (self.keys[0..self.len]) |key| if (window.tabIndexByKey(key) != null) {
                round.keys[round.len] = key;
                round.len += 1;
            };
            for (0..window.tab_count) |i| {
                const key = window.tabKey(i);
                if (std.mem.indexOfScalar(usize, round.keys[0..round.len], key) == null) {
                    round.keys[round.len] = key;
                    round.len += 1;
                }
            }
            self.round = round;
        }
        const round = &self.round.?;
        if (round.len < 2) return null;
        round.at = if (backwards) (round.at + round.len - 1) % round.len else (round.at + 1) % round.len;
        return window.tabIndexByKey(round.keys[round.at]);
    }

    /// Ctrl was released: the tab reached becomes the most recent.
    pub fn end(self: *Recent, window: *Window) void {
        if (self.round == null) return;
        self.round = null;
        if (window.tab_count > 0) self.used(window.tabKey(window.active_tab));
    }
};
