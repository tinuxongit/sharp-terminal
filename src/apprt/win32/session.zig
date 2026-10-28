//! What the sidebar layout restores at startup: each window's tabs (shell
//! profile, folder, and the server it was connected to), which tab was
//! active, folded groups, the sidebar's width and the servers connected to
//! recently. Kept as a small text file beside Ghostty's config:
//!
//!     width = 260
//!     collapsed = C:\Users\me\old-project
//!     server = me@example.com
//!     window = 1
//!     tab = Windows PowerShell|C:\Users\me\project
//!     tab = Command Prompt|C:\Users\me|me@example.com
//!
//! `window = N` starts a window whose active tab is the Nth (from 0);
//! `|` separates a tab's profile, folder and server, since no Windows path
//! may contain it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");

const file_name = "sharp-session";
const max_size = 256 * 1024;

pub const Tab = struct {
    profile: []const u8,
    folder: []const u8,
    /// The SSH destination, or empty for a local tab.
    server: []const u8 = "",
};

pub const Window = struct {
    tabs: []const Tab,
    active: usize,
};

pub const Session = struct {
    windows: []const Window,
    /// Sidebar width in pixels at 96 DPI.
    width: f32,
    collapsed: []const []const u8,
    /// Servers connected to, most recent first.
    servers: []const []const u8,
};

/// A loaded session. Everything lives in the arena.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    session: Session,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

fn path(alloc: Allocator) ![]u8 {
    const config_path = try configpkg.edit.openPath(alloc);
    defer alloc.free(config_path);
    const dir = std.fs.path.dirname(config_path) orelse return error.NoConfigFolder;
    return std.fs.path.join(alloc, &.{ dir, file_name });
}

/// The saved session, or null when there is none. A malformed line is
/// skipped rather than discarding everything else.
pub fn load(alloc: Allocator, default_width: f32) !?Loaded {
    const file = try path(alloc);
    defer alloc.free(file);
    const text = std.Io.Dir.cwd().readFileAlloc(global.io(), file, alloc, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(text);

    var loaded: Loaded = .{ .arena = .init(alloc), .session = .{ .windows = &.{}, .width = default_width, .collapsed = &.{}, .servers = &.{} } };
    errdefer loaded.arena.deinit();
    const a = loaded.arena.allocator();

    var windows: std.ArrayList(Window) = .empty;
    var tabs: std.ArrayList(Tab) = .empty;
    var collapsed: std.ArrayList([]const u8) = .empty;
    var servers: std.ArrayList([]const u8) = .empty;
    var active: usize = 0;
    var in_window = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "width")) {
            const width = std.fmt.parseFloat(f32, value) catch continue;
            // nan or inf would reach an int conversion when laid out.
            if (std.math.isFinite(width)) loaded.session.width = width;
        } else if (std.mem.eql(u8, key, "collapsed")) {
            try collapsed.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "server")) {
            try servers.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "window")) {
            if (in_window) try windows.append(a, .{ .tabs = try tabs.toOwnedSlice(a), .active = active });
            active = std.fmt.parseInt(usize, value, 10) catch 0;
            in_window = true;
        } else if (std.mem.eql(u8, key, "tab") and in_window) {
            var fields = std.mem.splitScalar(u8, value, '|');
            const profile = fields.first();
            const folder = fields.next() orelse continue;
            const server = fields.next() orelse "";
            try tabs.append(a, .{ .profile = try a.dupe(u8, profile), .folder = try a.dupe(u8, folder), .server = try a.dupe(u8, server) });
        }
    }
    if (in_window) try windows.append(a, .{ .tabs = try tabs.toOwnedSlice(a), .active = active });

    loaded.session.windows = try windows.toOwnedSlice(a);
    loaded.session.collapsed = try collapsed.toOwnedSlice(a);
    loaded.session.servers = try servers.toOwnedSlice(a);
    return loaded;
}

pub fn save(alloc: Allocator, session: Session) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "# Tabs Sharp reopens at startup in the sidebar layout. Rewritten as tabs change.\n");
    try out.print(alloc, "width = {d}\n", .{session.width});
    for (session.collapsed) |folder| try out.print(alloc, "collapsed = {s}\n", .{folder});
    for (session.servers) |server| try out.print(alloc, "server = {s}\n", .{server});
    for (session.windows) |window| {
        try out.print(alloc, "window = {d}\n", .{window.active});
        for (window.tabs) |tab| {
            try out.print(alloc, "tab = {s}|{s}", .{ tab.profile, tab.folder });
            if (tab.server.len > 0) try out.print(alloc, "|{s}", .{tab.server});
            try out.append(alloc, '\n');
        }
    }
    const file = try path(alloc);
    defer alloc.free(file);
    try std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = file, .data = out.items });
}
