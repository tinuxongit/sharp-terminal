const std = @import("std");
const global = @import("../../global.zig");
const HiddenCli = @import("HiddenCli.zig");
const servers = @import("servers.zig");

pub const max_path = 512;
pub const max_identities = 8;

pub const Path = struct {
    buf: [max_path]u8 = undefined,
    len: u16 = 0,

    pub fn text(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Settings = struct {
    hostname: servers.Name = .{},
    user: servers.Name = .{},
    identities: [max_identities]Path = undefined,
    identity_count: usize = 0,

    pub fn identityFiles(self: *const Settings) []const Path {
        return self.identities[0..self.identity_count];
    }
};

pub fn read(alloc: std.mem.Allocator, destination: []const u8) ?Settings {
    if (!servers.valid(destination)) return null;
    var line_buf: [256]u8 = undefined;
    const command = std.fmt.bufPrint(&line_buf, "ssh.exe -G {s}", .{destination}) catch return null;
    var cli = HiddenCli.startWithin(command, 10_000) orelse return null;
    defer cli.end();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    cli.readAll(alloc, &out);

    const home = global.environ().getAlloc(alloc, "USERPROFILE") catch return null;
    defer alloc.free(home);
    var settings: Settings = .{};
    var lines = std.mem.tokenizeAny(u8, out.items, "\r\n");
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "hostname") and servers.valid(value)) {
            settings.hostname = .init(value);
        } else if (std.mem.eql(u8, key, "user") and servers.valid(value)) {
            settings.user = .init(value);
        } else if (std.mem.eql(u8, key, "identityfile") and settings.identity_count < max_identities) {
            if (expandHome(&settings.identities[settings.identity_count], home, value)) settings.identity_count += 1;
        }
    }
    if (settings.hostname.len == 0) return null;
    return settings;
}

fn expandHome(out: *Path, home: []const u8, value: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, value, "~/") or std.mem.startsWith(u8, value, "~\\")) value[1..] else {
        if (value.len > max_path) return false;
        @memcpy(out.buf[0..value.len], value);
        out.len = @intCast(value.len);
        return true;
    };
    const written = std.fmt.bufPrint(&out.buf, "{s}{s}", .{ home, rest }) catch return false;
    for (written) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    out.len = @intCast(written.len);
    return true;
}
