//! The SSH servers the sidebar offers: hosts named in the user's OpenSSH
//! config, and those connected to recently (kept in the session file).
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

pub const max_len = 128;
const max_config_size = 256 * 1024;

/// Fixed-size text, so lists of servers need no allocation.
pub const Name = struct {
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn init(value: []const u8) Name {
        var name: Name = .{};
        name.len = @intCast(@min(value.len, max_len));
        @memcpy(name.buf[0..name.len], value[0..name.len]);
        return name;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Servers connected to, most recent first.
pub const Recent = struct {
    pub const capacity = 10;

    items: [capacity]Name = undefined,
    len: usize = 0,

    /// Put `destination` first, moving it up if it was already listed.
    /// Returns whether the list changed.
    pub fn add(self: *Recent, destination: []const u8) bool {
        if (destination.len == 0 or destination.len > max_len) return false;
        const at = for (self.items[0..self.len], 0..) |*item, i| {
            if (std.ascii.eqlIgnoreCase(item.text(), destination)) break i;
        } else null;
        if (at == 0) return false;
        const shift = at orelse @min(self.len, capacity - 1);
        std.mem.copyBackwards(Name, self.items[1 .. shift + 1], self.items[0..shift]);
        self.items[0] = .init(destination);
        if (at == null) self.len = @min(self.len + 1, capacity);
        return true;
    }

    pub fn names(self: *const Recent, out: *[capacity][]const u8) []const []const u8 {
        for (self.items[0..self.len], 0..) |*item, i| out[i] = item.text();
        return out[0..self.len];
    }
};

/// Whether `destination` can go on ssh's command line as a destination
/// and nothing else, such as "user@host" or an IPv6 address. Anything
/// starting with "-" would be read as an option.
pub fn valid(destination: []const u8) bool {
    if (destination.len == 0 or destination.len > max_len or destination[0] == '-') return false;
    for (destination) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "@._-:[]%", c) != null;
        if (!ok) return false;
    }
    return true;
}

/// The `Host` aliases in ~/.ssh/config, without patterns, in file order.
pub const Configured = struct {
    pub const capacity = 30;

    items: [capacity]Name = undefined,
    len: usize = 0,

    pub fn read(alloc: Allocator) Configured {
        var self: Configured = .{};
        const home = global.environ().getAlloc(alloc, "USERPROFILE") catch return self;
        defer alloc.free(home);
        const path = std.fs.path.join(alloc, &.{ home, ".ssh", "config" }) catch return self;
        defer alloc.free(path);
        const contents = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_config_size)) catch return self;
        defer alloc.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            // "Host a b" or "Host=a b"; the keyword ignores case.
            if (line.len < 5 or !std.ascii.eqlIgnoreCase(line[0..4], "host")) continue;
            const rest = std.mem.trimStart(u8, line[4..], " \t=");
            if (rest.len == line.len - 4) continue; // "HostName", not "Host"
            var aliases = std.mem.tokenizeAny(u8, rest, " \t");
            while (aliases.next()) |alias| {
                if (std.mem.indexOfAny(u8, alias, "*?!") != null or !valid(alias)) continue;
                if (self.len == capacity) return self;
                self.items[self.len] = .init(alias);
                self.len += 1;
            }
        }
        return self;
    }

    pub fn names(self: *const Configured, out: *[capacity][]const u8) []const []const u8 {
        for (self.items[0..self.len], 0..) |*item, i| out[i] = item.text();
        return out[0..self.len];
    }
};
