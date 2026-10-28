//! Tabs closed lately, newest last, which `undo` (the command palette's
//! "Reopen Closed Tab", Windows Terminal's restoreLastClosed) opens again
//! as the session restores a tab: its shell, folder, server and Claude
//! Code conversation, not its output, whose programs have ended.
const std = @import("std");
const session = @import("session.zig");
const workspace = @import("workspace.zig");
const Window = @import("Window.zig");

/// One closed tab, its text copied out of the surface that is gone.
pub const Entry = struct {
    profile: Text(128) = .{},
    folder: Text(1024) = .{},
    server: Text(256) = .{},
    claude: Text(64) = .{},

    pub fn tab(self: *const Entry) session.Tab {
        return .{
            .profile = self.profile.slice(),
            .folder = self.folder.slice(),
            .server = self.server.slice(),
            .claude = self.claude.slice(),
        };
    }
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), text: []const u8) bool {
            if (text.len > n) return false;
            @memcpy(self.buf[0..text.len], text);
            self.len = text.len;
            return true;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

var entries: [10]Entry = undefined;
var len: usize = 0;

/// Remember a tab as it closes; the oldest goes when there are ten.
pub fn remember(tab: session.Tab) void {
    var entry: Entry = .{};
    // A text too long to copy whole would reopen somewhere else.
    if (!entry.profile.set(tab.profile) or !entry.folder.set(tab.folder) or
        !entry.server.set(tab.server) or !entry.claude.set(tab.claude)) return;
    if (len == entries.len) {
        std.mem.copyForwards(Entry, entries[0 .. len - 1], entries[1..len]);
        len -= 1;
    }
    entries[len] = entry;
    len += 1;
}

pub fn any() bool {
    return len > 0;
}

/// Open the most recently closed tab again in `window`; false if none.
pub fn reopen(window: *Window) bool {
    if (len == 0) return false;
    len -= 1;
    const entry = entries[len];
    workspace.openSavedTab(window, entry.tab());
    return true;
}
