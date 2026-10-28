//! sharp-mcp.exe: the MCP server command Claude Code runs. It passes
//! Claude's stdio to and from the running Sharp over its named pipe, so
//! the browser tools act on the panel the user sees.
const std = @import("std");
const w32 = @import("win32.zig");
const mcp_pipe = @import("mcp_pipe.zig");

pub fn main() u8 {
    const stdin = w32.GetStdHandle(w32.STD_INPUT_HANDLE) orelse return 1;
    const stdout = w32.GetStdHandle(w32.STD_OUTPUT_HANDLE) orelse return 1;
    var buf: mcp_pipe.Name = undefined;
    const name = mcp_pipe.name(&buf) orelse return 1;
    const pipe = connect(name) orelse {
        report("Sharp isn't running, or its browser is off in Settings > AI > Tools.\n");
        return 1;
    };
    // Another account could have made a pipe of this name first.
    if (!mcp_pipe.servedByUs(pipe)) {
        report("The pipe isn't served by Sharp running as this user; not connecting.\n");
        return 1;
    }
    // Both sides are polled from one thread: a blocking read on the pipe
    // would hold up writes to it, since its handle is synchronous.
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const moved_in = move(stdin, pipe, &chunk) orelse return 0;
        const moved_out = move(pipe, stdout, &chunk) orelse return 0;
        if (!moved_in and !moved_out) w32.Sleep(5);
    }
}

fn connect(name: [*:0]const u16) ?w32.HANDLE {
    for (0..10) |_| {
        if (w32.validHandle(w32.CreateFileW(name, w32.GENERIC_READ | w32.GENERIC_WRITE, 0, null, w32.OPEN_EXISTING, 0, null))) |h| return h;
        // Every instance is busy until Sharp makes the next one.
        if (w32.GetLastError() != w32.ERROR_PIPE_BUSY) return null;
        _ = w32.WaitNamedPipeW(name, 1000);
    }
    return null;
}

/// Pass along what `from` has waiting. Null once either side closed.
fn move(from: w32.HANDLE, to: w32.HANDLE, chunk: []u8) ?bool {
    var avail: u32 = 0;
    if (w32.PeekNamedPipe(from, null, 0, null, &avail, null) == 0) return null;
    if (avail == 0) return false;
    var got: u32 = 0;
    if (w32.ReadFile(from, chunk.ptr, @min(avail, @as(u32, @intCast(chunk.len))), &got, null) == 0) return null;
    var left = chunk[0..got];
    while (left.len > 0) {
        var wrote: u32 = 0;
        if (w32.WriteFile(to, left.ptr, @intCast(left.len), &wrote, null) == 0) return null;
        left = left[wrote..];
    }
    return true;
}

fn report(text: []const u8) void {
    const stderr = w32.GetStdHandle(w32.STD_ERROR_HANDLE) orelse return;
    var wrote: u32 = 0;
    _ = w32.WriteFile(stderr, text.ptr, @intCast(text.len), &wrote, null);
}
