const std = @import("std");
const server_query = @import("server_query.zig");
const server_shell = @import("server_shell.zig");
const tools = @import("server_tools.zig").data;

pub const Arch = enum { amd64, arm64, other };

pub const Probe = struct {
    home_buf: [server_shell.max_folder_len]u8 = undefined,
    home_len: usize = 0,
    arch: Arch = .other,
    has_files: bool = false,
    has_apps: bool = false,

    pub fn home(self: *const Probe) []const u8 {
        return self.home_buf[0..self.home_len];
    }
};

pub const Result = union(enum) {
    probe: Probe,
    sign_in_needed,
    unreachable_server,
};

const end_marker = "SHARP-END";

pub const files_binary = "$HOME/.local/share/sharp/filebrowser-" ++ tools.files.version ++ "/filebrowser";
pub const vnc_server = "$(command -v Xtigervnc || command -v Xvnc)";
const script =
    "echo \"$HOME\"; uname -m; " ++
    "[ -x \"" ++ files_binary ++ "\" ] && echo files; " ++
    "[ -n \"" ++ vnc_server ++ "\" ] && command -v websockify >/dev/null && [ -f /usr/share/novnc/vnc.html ] && echo apps; " ++
    "echo " ++ end_marker;

pub fn read(alloc: std.mem.Allocator, destination: []const u8) Result {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (!server_query.run(alloc, destination, script, &out)) return .unreachable_server;
    if (std.mem.indexOf(u8, out.items, end_marker) == null) {
        return if (server_query.deniedPassword(out.items)) .sign_in_needed else .unreachable_server;
    }
    var probe: Probe = .{};
    var lines = std.mem.tokenizeAny(u8, out.items, "\r\n");
    const home_line = lines.next() orelse return .unreachable_server;
    if (!server_shell.validFolder(home_line) or std.mem.indexOfAny(u8, home_line, ": ") != null) return .unreachable_server;
    @memcpy(probe.home_buf[0..home_line.len], home_line);
    probe.home_len = home_line.len;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "x86_64")) probe.arch = .amd64;
        if (std.mem.eql(u8, line, "aarch64") or std.mem.eql(u8, line, "arm64")) probe.arch = .arm64;
        if (std.mem.eql(u8, line, "files")) probe.has_files = true;
        if (std.mem.eql(u8, line, "apps")) probe.has_apps = true;
    }
    return .{ .probe = probe };
}
