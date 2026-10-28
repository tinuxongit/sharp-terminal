//! Reads and changes single settings in the user's Ghostty config file,
//! leaving every other line and comment as the user wrote it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");

/// Larger files are not something a person keeps by hand.
const max_size = 1024 * 1024;

/// The config file's contents, created empty if it doesn't exist yet.
pub fn read(alloc: Allocator) ![]u8 {
    const path = try configpkg.edit.openPath(alloc);
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_size));
}

/// Set `key` to `value`, or remove it when `value` is empty so the default
/// applies. Repeatable keys like font-family end up with the one value.
pub fn write(alloc: Allocator, key: []const u8, value: []const u8) !void {
    const path = try configpkg.edit.openPath(alloc);
    defer alloc.free(path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_size));
    defer alloc.free(contents);
    const updated = try withValue(alloc, contents, key, value);
    defer alloc.free(updated);
    try std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = path, .data = updated });
}

/// The value of the last line setting `key`, as Ghostty reads it: the
/// last definition wins.
pub fn currentValue(contents: []const u8, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (parse(line)) |entry| {
            if (std.mem.eql(u8, entry.key, key)) found = entry.value;
        }
    }
    return found;
}

/// Compare two config values, ignoring quotes around the whole value.
pub fn sameValue(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, unquote(a), unquote(b));
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"' and
        std.mem.indexOfScalar(u8, v[1 .. v.len - 1], '"') == null) return v[1 .. v.len - 1];
    return v;
}

const Entry = struct { key: []const u8, value: []const u8 };

fn parse(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], " \t"),
        .value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t"),
    };
}

fn withValue(alloc: Allocator, contents: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (parse(line)) |entry| {
            if (std.mem.eql(u8, entry.key, key)) continue;
        }
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
        first = false;
    }
    if (value.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.print(alloc, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(alloc);
}
