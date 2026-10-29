//! Sharp's MCP server for Claude Code: JSON-RPC lines over the named pipe
//! that the sharp-mcp bridge connects Claude's stdio to, offering the
//! browser tools. It runs only while Settings > AI > Tools > Browser is on.
const std = @import("std");
const w32 = @import("win32.zig");
const mcp_pipe = @import("mcp_pipe.zig");
const browser_tools = @import("browser_tools.zig");

const log = std.log.scoped(.win32);

/// Sharp's version, which Claude Code shows beside the server.
const version = "0.1.0";
/// Answered when the client asks for none.
const default_protocol = "2025-06-18";

var running: std.atomic.Value(bool) = .init(false);
/// Bumped at every start, so a listener left from before a quick off and
/// on knows it is not the current one.
var generation: std.atomic.Value(u32) = .init(0);
/// A client sending more than this without a line break is cut off.
const max_line = 8 * 1024 * 1024;

/// Follow the setting: start listening, or stop taking new clients and
/// refuse tool calls from connected ones.
pub fn setEnabled(on: bool) void {
    if (running.swap(on, .acq_rel) == on) return;
    if (on) {
        const thread = std.Thread.spawn(.{}, listen, .{generation.fetchAdd(1, .acq_rel) + 1}) catch |err| {
            log.warn("failed to start the MCP server: {}", .{err});
            running.store(false, .release);
            return;
        };
        thread.detach();
    } else {
        // The listener waits for a client; one that connects and leaves
        // lets it see it should stop.
        var buf: mcp_pipe.Name = undefined;
        const name = mcp_pipe.name(&buf) orelse return;
        if (w32.validHandle(w32.CreateFileW(name, w32.GENERIC_READ | w32.GENERIC_WRITE, 0, null, w32.OPEN_EXISTING, 0, null))) |h| _ = w32.CloseHandle(h);
    }
}

fn current(mine: u32) bool {
    return running.load(.acquire) and generation.load(.acquire) == mine;
}

fn listen(mine: u32) void {
    var buf: mcp_pipe.Name = undefined;
    const name = mcp_pipe.name(&buf) orelse return;
    var security = mcp_pipe.ownerOnly() orelse {
        log.warn("could not limit the MCP pipe to this user; not serving", .{});
        return;
    };
    var first = true;
    var attempts: u32 = 0;
    while (current(mine)) {
        // The first instance refuses a pipe someone else already made, so
        // no other program can pose as Sharp's server.
        const raw = w32.CreateNamedPipeW(
            name,
            w32.PIPE_ACCESS_DUPLEX | if (first) w32.FILE_FLAG_FIRST_PIPE_INSTANCE else 0,
            w32.PIPE_TYPE_BYTE | w32.PIPE_READMODE_BYTE | w32.PIPE_WAIT | w32.PIPE_REJECT_REMOTE_CLIENTS,
            w32.PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            0,
            &security,
        );
        const pipe = w32.validHandle(raw) orelse {
            // A listener from before a quick off and on may still hold it.
            attempts += 1;
            if (attempts < 20) {
                w32.Sleep(100);
                continue;
            }
            log.warn("the MCP pipe is taken, probably by another Sharp (error {d})", .{w32.GetLastError()});
            return;
        };
        first = false;
        attempts = 0;
        const connected = w32.ConnectNamedPipe(pipe, null) != 0 or w32.GetLastError() == w32.ERROR_PIPE_CONNECTED;
        if (!connected or !current(mine)) {
            _ = w32.CloseHandle(pipe);
            continue;
        }
        const thread = std.Thread.spawn(.{}, serve, .{pipe}) catch {
            _ = w32.CloseHandle(pipe);
            continue;
        };
        thread.detach();
    }
}

/// One client: a request per line, answered in order.
fn serve(pipe: w32.HANDLE) void {
    defer {
        _ = w32.DisconnectNamedPipe(pipe);
        _ = w32.CloseHandle(pipe);
    }
    const gpa = std.heap.smp_allocator;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (w32.ReadFile(pipe, &chunk, chunk.len, &got, null) == 0 or got == 0) return;
        pending.appendSlice(gpa, chunk[0..got]) catch return;
        if (pending.items.len > max_line and std.mem.indexOfScalar(u8, pending.items, '\n') == null) return;
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const reply = answer(arena.allocator(), pending.items[0..nl]) catch null;
            const rest = pending.items.len - nl - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[nl + 1 ..]);
            pending.shrinkRetainingCapacity(rest);
            if (reply) |r| if (!writeAll(pipe, r)) return;
        }
    }
}

fn writeAll(pipe: w32.HANDLE, bytes: []const u8) bool {
    var left = bytes;
    while (left.len > 0) {
        var wrote: u32 = 0;
        if (w32.WriteFile(pipe, left.ptr, @intCast(@min(left.len, 1 << 20)), &wrote, null) == 0) return false;
        left = left[wrote..];
    }
    return true;
}

/// The reply line to one JSON-RPC message, or null for notifications.
fn answer(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const message = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (message != .object) return null;
    const id = message.object.get("id") orelse return null;
    const method = if (message.object.get("method")) |m| (if (m == .string) m.string else "") else "";
    const params = message.object.get("params") orelse std.json.Value{ .null = {} };

    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    try json.write(id);
    if (std.mem.eql(u8, method, "initialize")) {
        const asked = if (params == .object) params.object.get("protocolVersion") else null;
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("protocolVersion");
        try json.write(if (asked != null and asked.? == .string) asked.?.string else default_protocol);
        try json.objectField("capabilities");
        try json.write(.{ .tools = struct {}{} });
        try json.objectField("serverInfo");
        try json.write(.{ .name = browser_tools.data.server_name, .version = version });
        try json.objectField("instructions");
        try json.write(browser_tools.data.instructions);
        try json.endObject();
    } else if (std.mem.eql(u8, method, "ping")) {
        try json.objectField("result");
        try json.write(struct {}{});
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("tools");
        try json.beginArray();
        for (browser_tools.data.tools) |tool| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(tool.name);
            try json.objectField("description");
            try json.write(tool.description);
            try json.objectField("inputSchema");
            try json.beginWriteRaw();
            try out.writer.writeAll(tool.schema);
            json.endWriteRaw();
            if (browser_tools.data.load_upfront) {
                try json.objectField("_meta");
                try json.write(.{ .@"anthropic/alwaysLoad" = true });
            }
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const name = if (params == .object) params.object.get("name") else null;
        const args = (if (params == .object) params.object.get("arguments") else null) orelse std.json.Value{ .object = .empty };
        const result: browser_tools.Output = if (!running.load(.acquire))
            .{ .is_error = true, .text = "The browser is off in Sharp's Settings > AI > Tools." }
        else if (name != null and name.? == .string)
            browser_tools.run(arena, name.?.string, args)
        else
            .{ .is_error = true, .text = "Name a tool to call." };
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("content");
        try json.beginArray();
        try json.write(.{ .type = "text", .text = result.text });
        if (result.image) |image| try json.write(.{ .type = "image", .data = image, .mimeType = "image/jpeg" });
        try json.endArray();
        try json.objectField("isError");
        try json.write(result.is_error);
        try json.endObject();
    } else {
        try json.objectField("error");
        try json.write(.{ .code = -32601, .message = "Method not found" });
    }
    try json.endObject();
    try out.writer.writeByte('\n');
    return out.written();
}
