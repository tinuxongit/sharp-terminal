//! What the browser panel's page reported (console messages, uncaught
//! errors, failed loads) since Claude last read it, for browser_logs and
//! for the errors an action caused. Kept on the UI thread, where WebView2
//! delivers the DevTools events.
const std = @import("std");
const json_read = @import("json_read.zig");
const field = json_read.field;
const string = json_read.string;

pub const Level = enum { debug, log, info, warning, @"error" };

/// The DevTools events the log listens to.
pub const Event = enum { console, exception, browser };

const capacity = 100;
const max_text = 500;

const Entry = struct {
    at_ms: u64,
    level: Level,
    text_buf: [max_text]u8,
    text_len: u16,

    fn text(self: *const Entry) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const Log = struct {
    entries: [capacity]Entry = undefined,
    /// Index of the oldest entry; the newest overwrite the oldest.
    start: usize = 0,
    count: usize = 0,

    fn at(self: *const Log, i: usize) *const Entry {
        return &self.entries[(self.start + i) % capacity];
    }

    pub fn add(self: *Log, at_ms: u64, level: Level, text: []const u8) void {
        const slot = if (self.count < capacity) (self.start + self.count) % capacity else blk: {
            const oldest = self.start;
            self.start = (self.start + 1) % capacity;
            break :blk oldest;
        };
        if (self.count < capacity) self.count += 1;
        // Cut at a whole UTF-8 character.
        var n = @min(text.len, max_text);
        while (n < text.len and n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
        const e = &self.entries[slot];
        e.* = .{ .at_ms = at_ms, .level = level, .text_buf = undefined, .text_len = @intCast(n) };
        @memcpy(e.text_buf[0..n], text[0..n]);
    }

    pub fn clear(self: *Log) void {
        self.count = 0;
    }

    /// One line per entry from `since_ms` on, oldest first.
    pub fn write(self: *const Log, w: *std.Io.Writer, since_ms: u64) std.Io.Writer.Error!void {
        for (0..self.count) |i| {
            const e = self.at(i);
            if (e.at_ms < since_ms) continue;
            try w.print("[{s}] {s}\n", .{ @tagName(e.level), e.text() });
        }
    }

    /// Record a DevTools event from its parameters. Each event names its
    /// fields differently, and unexpected shapes are skipped.
    pub fn addEvent(self: *Log, alloc: std.mem.Allocator, at_ms: u64, event: Event, params_json: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, params_json, .{}) catch return;
        defer parsed.deinit();
        const params = parsed.value;
        var buf: [max_text]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        switch (event) {
            // Runtime.consoleAPICalled: type and args (RemoteObjects).
            .console => {
                const args = field(params, "args") orelse return;
                if (args != .array) return;
                for (args.array.items, 0..) |arg, i| {
                    if (i > 0) w.writeByte(' ') catch break;
                    remoteText(&w, arg) catch break;
                }
                const kind = string(params, "type") orelse "log";
                self.add(at_ms, levelOf(kind), w.buffered());
            },
            // Runtime.exceptionThrown: exceptionDetails.
            .exception => {
                const details = field(params, "exceptionDetails") orelse return;
                const description = if (field(details, "exception")) |e| string(e, "description") else null;
                self.add(at_ms, .@"error", description orelse string(details, "text") orelse return);
            },
            // Log.entryAdded: entry with level, text and url. Failed loads
            // arrive here with source "network".
            .browser => {
                const entry = field(params, "entry") orelse return;
                if (std.mem.eql(u8, string(entry, "source") orelse "", "network")) return;
                const level = levelOf(string(entry, "level") orelse return);
                if (level != .warning and level != .@"error") return;
                w.writeAll(string(entry, "text") orelse return) catch {};
                if (string(entry, "url")) |url| w.print(" ({s})", .{url}) catch {};
                self.add(at_ms, level, w.buffered());
            },
        }
    }
};

fn levelOf(name: []const u8) Level {
    if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "assert")) return .@"error";
    if (std.mem.eql(u8, name, "warning") or std.mem.eql(u8, name, "warn")) return .warning;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "debug") or std.mem.eql(u8, name, "verbose")) return .debug;
    return .log;
}

/// A console argument as console.log shows it: strings bare, other
/// values as JSON or their description.
fn remoteText(w: *std.Io.Writer, arg: std.json.Value) std.Io.Writer.Error!void {
    if (string(arg, "type")) |t| {
        if (std.mem.eql(u8, t, "string")) {
            if (string(arg, "value")) |s| return w.writeAll(s);
        }
    }
    if (field(arg, "value")) |v| return std.json.Stringify.value(v, .{}, w);
    const text = string(arg, "unserializableValue") orelse string(arg, "description") orelse string(arg, "type") orelse "";
    try w.writeAll(text);
}
