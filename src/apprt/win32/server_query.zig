const std = @import("std");
const w32 = @import("win32.zig");
const command_line = @import("command_line.zig");
const servers = @import("servers.zig");
const HiddenCli = @import("HiddenCli.zig");

const timeout_ms = 15_000;

pub fn run(alloc: std.mem.Allocator, destination: []const u8, script: []const u8, out: *std.ArrayList(u8)) bool {
    if (!servers.valid(destination)) return false;
    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    command.writer.print("ssh.exe -o BatchMode=yes -o ConnectTimeout=5 {s} ", .{destination}) catch return false;
    command_line.quote(&command.writer, "", script) catch return false;

    const previous_cursor = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_WAIT));
    defer _ = w32.SetCursor(previous_cursor);
    var cli = HiddenCli.startWithin(command.written(), timeout_ms) orelse return false;
    defer cli.end();
    cli.readAll(alloc, out);
    return true;
}

pub fn deniedPassword(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "Permission denied") != null or
        std.mem.indexOf(u8, output, "password") != null;
}
