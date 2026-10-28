//! Reading fields of a parsed JSON value loosely: a field that is missing
//! or of another type reads as null, as the browser's DevTools answers and
//! Claude's tool arguments need.
const std = @import("std");
const Value = std.json.Value;

pub fn field(value: Value, name: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(name);
}

pub fn string(value: Value, name: []const u8) ?[]const u8 {
    const v = field(value, name) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn boolean(value: Value, name: []const u8) ?bool {
    const v = field(value, name) orelse return null;
    return if (v == .bool) v.bool else null;
}

pub fn number(value: Value, name: []const u8) ?f64 {
    return asNumber(field(value, name) orelse return null);
}

pub fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}
