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
    /// Closed outlines as x, y pairs in a 24-unit square, filled even-odd.
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
            var crossings: [max_crossings]f32 = undefined;
            var count: usize = 0;
            for (logo.shapes) |shape| {
                const points = shape.len / 2;
                for (0..points) |k| {
                    const x0 = shape[2 * k];
                    const y0 = shape[2 * k + 1];
                    const x1 = shape[2 * ((k + 1) % points)];
                    const y1 = shape[2 * ((k + 1) % points) + 1];
                    if ((y0 <= sample_y) == (y1 <= sample_y) or count == max_crossings) continue;
                    crossings[count] = (x0 + (sample_y - y0) * (x1 - x0) / (y1 - y0)) * scale;
                    count += 1;
                }
            }
            std.mem.sort(f32, crossings[0..count], {}, std.sort.asc(f32));
            // Even-odd: inside between the 1st and 2nd crossing, 3rd and 4th...
            var i: usize = 0;
            while (i + 1 < count) : (i += 2) addSpan(&coverage, n, crossings[i], crossings[i + 1]);
        }
        for (0..n) |px| {
            if (coverage[px] > 0) c.blend(x + @as(i32, @intCast(px)), y + @as(i32, @intCast(py)), paint, @min(1, coverage[px] / samples));
        }
    }
}

/// Add the part of each pixel the span from `a` to `b` covers.
fn addSpan(coverage: *[max_size]f32, n: usize, a: f32, b: f32) void {
    const first: usize = @intFromFloat(std.math.clamp(@floor(a), 0, @as(f32, @floatFromInt(n))));
    const last: usize = @intFromFloat(std.math.clamp(@ceil(b), 0, @as(f32, @floatFromInt(n))));
    for (first..last) |px| {
        const left: f32 = @floatFromInt(px);
        coverage[px] += @max(0, @min(b, left + 1) - @max(a, left));
    }
}
