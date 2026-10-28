//! Sharp's release versions, as tagged on GitHub: stable "0.1.1" and
//! nightly "0.1.2-nightly.20261028.3" (the next version, the UTC date and
//! the day's build). Nightlies of a version come before its stable
//! release, as in semver.
const std = @import("std");

pub const Channel = enum { stable, nightly };

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Set on nightlies.
    nightly: ?struct { date: u32, build: u32 } = null,

    pub fn channel(self: Version) Channel {
        return if (self.nightly != null) .nightly else .stable;
    }

    /// "0.1.1" or "0.1.2-nightly.20261028.3"; anything else is null.
    pub fn parse(text: []const u8) ?Version {
        const dash = std.mem.indexOfScalar(u8, text, '-');
        var core = std.mem.splitScalar(u8, text[0 .. dash orelse text.len], '.');
        var v: Version = .{
            .major = number(core.next()) orelse return null,
            .minor = number(core.next()) orelse return null,
            .patch = number(core.next()) orelse return null,
        };
        if (core.next() != null) return null;
        const pre = text[(dash orelse return v) + 1 ..];
        var parts = std.mem.splitScalar(u8, pre, '.');
        if (!std.mem.eql(u8, parts.next() orelse return null, "nightly")) return null;
        const date_text = parts.next() orelse return null;
        if (date_text.len != 8) return null;
        v.nightly = .{ .date = number(date_text) orelse return null, .build = number(parts.next()) orelse return null };
        if (parts.next() != null) return null;
        return v;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        const an = a.nightly orelse return if (b.nightly == null) .eq else .gt;
        const bn = b.nightly orelse return .lt;
        const by_date = std.math.order(an.date, bn.date);
        return if (by_date != .eq) by_date else std.math.order(an.build, bn.build);
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.order(b) == .eq;
    }
};

fn number(text: ?[]const u8) ?u32 {
    const t = text orelse return null;
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}
