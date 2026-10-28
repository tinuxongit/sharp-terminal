//! What the browser panel is set up with: browser.zon, checked when Sharp
//! is compiled, and the search engine setting; and what an address typed
//! into it means.
const std = @import("std");
const settings = @import("settings.zig");

pub const Engine = struct {
    id: []const u8,
    name: []const u8,
    home: []const u8,
    search: []const u8,
};

pub const Data = struct {
    width_percent: u8,
    min_width: f32,
    viewport_width: u32,
    viewport_height: u32,
    max_tabs: u8,
    engines: []const Engine,
    address_placeholder: []const u8,
    untitled: []const u8,
    unavailable: []const u8,
};

pub const data: Data = @import("browser.zon");

pub const search_engine_key = "browser-search-engine";

comptime {
    if (data.width_percent < 10 or data.width_percent > 80)
        @compileError("browser.zon: width_percent must be between 10 and 80");
    if (data.viewport_width < 320 or data.viewport_height < 240)
        @compileError("browser.zon: the viewport must be at least 320 × 240");
    if (data.max_tabs < 1 or data.engines.len < 1)
        @compileError("browser.zon: needs at least one tab and one engine");
    // Settings > AI > Tools offers only engines browser.zon has; "" is
    // the default, the first.
    @setEvalBranchQuota(10_000);
    for (settings.data.categories) |category| for (category.sections) |section| for (section.settings) |setting| {
        if (!std.mem.eql(u8, setting.key, search_engine_key)) continue;
        for (setting.choices) |choice| {
            if (choice.value.len > 0 and engineIndex(choice.value) == null)
                @compileError("settings.zon offers a search engine browser.zon lacks: " ++ choice.value);
        }
    };
}

fn engineIndex(id: []const u8) ?usize {
    for (data.engines, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
    return null;
}

/// The engine `browser-search-engine` names, or the first.
pub fn engineFor(id: ?[]const u8) *const Engine {
    return &data.engines[if (id) |i| engineIndex(i) orelse 0 else 0];
}

/// The page meant by `typed`: an address, with or without its scheme, or
/// words to look up with `search`.
pub fn addressFor(typed: []const u8, search: []const u8, out: []u8) ?[]const u8 {
    if (typed.len == 0) return null;
    var w: std.Io.Writer = .fixed(out);
    const has_scheme = std.mem.indexOf(u8, typed, "://") != null or
        std.mem.startsWith(u8, typed, "about:") or std.mem.startsWith(u8, typed, "data:");
    const looks_like_host = std.mem.indexOfScalar(u8, typed, ' ') == null and
        (std.mem.indexOfScalar(u8, typed, '.') != null or std.mem.startsWith(u8, typed, "localhost"));
    if (has_scheme) {
        w.writeAll(typed) catch return null;
    } else if (looks_like_host) {
        // Local servers rarely have certificates.
        const local = std.mem.startsWith(u8, typed, "localhost") or std.mem.startsWith(u8, typed, "127.0.0.1");
        w.print("{s}{s}", .{ if (local) "http://" else "https://", typed }) catch return null;
    } else {
        w.writeAll(search) catch return null;
        for (typed) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                w.writeByte(c) catch return null;
            } else if (c == ' ') {
                w.writeByte('+') catch return null;
            } else {
                w.print("%{X:0>2}", .{c}) catch return null;
            }
        }
    }
    return w.buffered();
}
