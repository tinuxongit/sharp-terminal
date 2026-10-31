const std = @import("std");
const terminfo = @import("../../terminfo/main.zig");
const servers = @import("servers.zig");

pub const max_folder_len = 512;

pub const Argv = struct {
    storage: [16 * 1024]u8 = undefined,
    args: [4][:0]const u8 = undefined,

    pub fn slice(self: *const Argv) []const [:0]const u8 {
        return &self.args;
    }
};

pub fn build(out: *Argv, destination: []const u8, folder: ?[]const u8, before: []const u8) ?*const Argv {
    if (!servers.valid(destination)) return null;
    var fba: std.heap.FixedBufferAllocator = .init(&out.storage);
    const alloc = fba.allocator();
    const script = remoteScript(alloc, folder, before) catch return null;
    out.args = .{
        "ssh.exe",
        "-t",
        alloc.dupeSentinel(u8, destination, 0) catch return null,
        script,
    };
    return out;
}

fn remoteScript(alloc: std.mem.Allocator, folder: ?[]const u8, before: []const u8) ![:0]const u8 {
    var script: std.Io.Writer.Allocating = .init(alloc);
    const w = &script.writer;
    try w.writeAll(before);
    try w.writeAll("infocmp xterm-ghostty >/dev/null 2>&1 || printf '%s' ");
    var source: std.Io.Writer.Allocating = .init(alloc);
    try terminfo.ghostty.encode(&source.writer);
    try writeQuoted(w, source.written());
    try w.writeAll(" | tic -x - >/dev/null 2>&1; infocmp xterm-ghostty >/dev/null 2>&1 || export TERM=xterm-256color; ");
    if (folder) |path| if (path.len > 0) {
        try w.writeAll("cd ");
        try writeQuoted(w, path);
        try w.writeAll(" 2>/dev/null; ");
    };
    try w.writeAll("exec $SHELL -l");
    return try script.toOwnedSliceSentinel(0);
}

pub fn writeQuoted(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

pub fn validFolder(path: []const u8) bool {
    if (path.len == 0 or path.len > max_folder_len) return false;
    if (path[0] != '/') return false;
    for (path) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}
