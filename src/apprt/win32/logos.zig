//! Tool logos from logos.zon (made from SVGs by dist/windows/make_logos.py),
//! filled into a Canvas with anti-aliased edges, at any size.
const std = @import("std");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

pub const Logo = struct {
    name: []const u8,
    /// Its own color, or null to draw in the caller's.
    color: ?u24,
    /// Fill where outlines cross an odd number of times; otherwise where
    /// they wind around a nonzero number of times (SVG's default).
    even_odd: bool,
    /// Closed outlines as x, y pairs in a 24-unit square.
    shapes: []const []const f32,
};

pub const all: []const Logo = @import("logos.zon");

/// The logo called `name`; at compile time a missing one is an error.
pub fn find(comptime name: []const u8) *const Logo {
    inline for (all) |*logo| {
        if (comptime std.mem.eql(u8, logo.name, name)) return logo;
    }
    @compileError("logos.zon has no logo named " ++ name);
}

const units = 24.0;
/// Rows sampled per pixel; across, each span's exact overlap counts.
const samples = 4;
const max_size = 128;
const max_crossings = 128;

/// Fill `logo` into the `size`-pixel square at `x`, `y`, in `color` unless
/// the logo has its own.
pub fn draw(c: Canvas, logo: *const Logo, x: i32, y: i32, size: i32, color: Rgb) void {
    if (size <= 0 or size > max_size) return;
    const paint: Rgb = if (logo.color) |own| .{ .r = @truncate(own >> 16), .g = @truncate(own >> 8), .b = @truncate(own) } else color;
    const n: usize = @intCast(size);
    const scale = @as(f32, @floatFromInt(size)) / units;
    for (0..n) |py| {
        var coverage: [max_size]f32 = @splat(0);
        for (0..samples) |sy| {
            const sample_y = (@as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples) / scale;
            var crossings: [max_crossings]Crossing = undefined;
            var count: usize = 0;
            for (logo.shapes) |shape| {
                const points = shape.len / 2;
                for (0..points) |k| {
                    const x0 = shape[2 * k];
                    const y0 = shape[2 * k + 1];
                    const x1 = shape[2 * ((k + 1) % points)];
                    const y1 = shape[2 * ((k + 1) % points) + 1];
                    if ((y0 <= sample_y) == (y1 <= sample_y) or count == max_crossings) continue;
                    crossings[count] = .{
                        .x = (x0 + (sample_y - y0) * (x1 - x0) / (y1 - y0)) * scale,
                        .up = y1 < y0,
                    };
                    count += 1;
                }
            }
            std.mem.sort(Crossing, crossings[0..count], {}, Crossing.before);
            // Walk the row left to right, filling while inside.
            var winding: i32 = 0;
            var entered: f32 = 0;
            for (crossings[0..count]) |cross| {
                const was_inside = winding != 0;
                winding = if (logo.even_odd) winding ^ 1 else winding + @as(i32, if (cross.up) 1 else -1);
                const inside = winding != 0;
                if (!was_inside and inside) entered = cross.x;
                if (was_inside and !inside) addSpan(&coverage, n, entered, cross.x);
            }
        }
        for (0..n) |px| {
            if (coverage[px] > 0) c.blend(x + @as(i32, @intCast(px)), y + @as(i32, @intCast(py)), paint, @min(1, coverage[px] / samples));
        }
    }
}

const Crossing = struct {
    x: f32,
    /// Which way the outline crosses, for the winding rule.
    up: bool,

    fn before(_: void, a: Crossing, b: Crossing) bool {
        return a.x < b.x;
    }
};

/// Add the part of each pixel the span from `a` to `b` covers.
fn addSpan(coverage: *[max_size]f32, n: usize, a: f32, b: f32) void {
    const first: usize = @intFromFloat(std.math.clamp(@floor(a), 0, @as(f32, @floatFromInt(n))));
    const last: usize = @intFromFloat(std.math.clamp(@ceil(b), 0, @as(f32, @floatFromInt(n))));
    for (first..last) |px| {
        const left: f32 = @floatFromInt(px);
        coverage[px] += @max(0, @min(b, left + 1) - @max(a, left));
    }
}
