//! Sharp's release versions, as tagged on GitHub ("v0.1.1").
const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// "0.1.1"; anything else is null.
    pub fn parse(text: []const u8) ?Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        const v: Version = .{
            .major = number(parts.next()) orelse return null,
            .minor = number(parts.next()) orelse return null,
            .patch = number(parts.next()) orelse return null,
        };
        if (parts.next() != null) return null;
        return v;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        return .eq;
    }
};

fn number(text: ?[]const u8) ?u32 {
    const t = text orelse return null;
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}
