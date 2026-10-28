//! Sharp's background styles (`background-style`). Ghostty draws images,
//! not patterns, so a style is made once per color as a PNG tile in
//! %LOCALAPPDATA%\Sharp\Backgrounds and handed to Ghostty as its
//! repeating, unscaled `background-image` when the config is loaded. The
//! config file itself is never touched.
const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const wide_string = @import("wide_string.zig");
const png = @import("png.zig");
const Config = @import("../../config.zig").Config;

const log = std.log.scoped(.win32);

const Cascade = struct {
    pitch: u32,
    dot: u32,
    columns: u32,
    height: u32,
    fade: f32,
    max_alpha: f32,
};

const data: struct { pixel_cascade: Cascade } = @import("backgrounds.zon");

comptime {
    const c = data.pixel_cascade;
    if (c.dot == 0 or c.dot > c.pitch) @compileError("backgrounds.zon: dot must be from 1 to pitch");
    if (c.max_alpha <= 0 or c.max_alpha > 1) @compileError("backgrounds.zon: max_alpha must be above 0 and at most 1");
    if (c.fade > @as(f32, @floatFromInt(c.height))) @compileError("backgrounds.zon: the fade must end within the tile");
    if (c.columns % 8 != 0) @compileError("backgrounds.zon: columns must be a multiple of 8, the cloudiness's lattice");
}

/// Bumped when the pattern changes, so tiles made by an older Sharp are
/// made again.
const version = 2;

/// Point `config`'s background image at its style's tile, making the tile
/// first if needed. The default style leaves the config as it is.
pub fn apply(config: *Config) void {
    if (config.@"background-style" == .default) return;
    const color = config.@"background-style-color" orelse config.foreground;
    const arena = if (config._arena) |*a| a else return;
    const path = tile(arena.allocator(), color) catch |err| {
        log.warn("could not make the background pattern: {}", .{err});
        return;
    };
    config.@"background-image" = .{ .required = path };
    config.@"background-image-position" = .@"top-left";
    config.@"background-image-fit" = .none;
    config.@"background-image-repeat" = true;
    config.@"background-image-opacity" = 1;
}

/// The tile's path for `color`, made now if it doesn't exist yet.
fn tile(alloc: std.mem.Allocator, color: Config.Color) ![:0]const u8 {
    var base_w: [1024]u16 = undefined;
    const len = w32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &base_w, base_w.len);
    if (len == 0 or len >= base_w.len) return error.NoLocalAppData;
    var base: [2048]u8 = undefined;
    const base_len = wide_string.toUtf8(&base, base_w[0..len]);
    const dir = try std.fmt.allocPrintSentinel(alloc, "{s}\\" ++ brand.name ++ "\\Backgrounds", .{base[0..base_len]}, 0);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}\\pixel-cascade-{x:0>2}{x:0>2}{x:0>2}-v{d}.png", .{ dir, color.r, color.g, color.b, version }, 0);

    const gpa = std.heap.smp_allocator;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);
    if (w32.GetFileAttributesW(path_w) != w32.INVALID_FILE_ATTRIBUTES) return path;

    // Both folders may be missing; existing ones are fine.
    const parent_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, dir[0 .. std.mem.lastIndexOfScalar(u8, dir, '\\') orelse dir.len]);
    defer gpa.free(parent_w);
    _ = w32.CreateDirectoryW(parent_w, null);
    const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, dir);
    defer gpa.free(dir_w);
    _ = w32.CreateDirectoryW(dir_w, null);

    const c = data.pixel_cascade;
    const width = c.columns * c.pitch;
    const pixels = try gpa.alloc(u8, @as(usize, width) * c.height * 4);
    defer gpa.free(pixels);
    drawCascade(pixels, width, color);
    const encoded = try png.encode(gpa, width, c.height, pixels);
    defer gpa.free(encoded);

    // Written beside it and moved into place, so a tile is never half there.
    const temp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmp", .{path}, 0);
    defer gpa.free(temp);
    const temp_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, temp);
    defer gpa.free(temp_w);
    try writeFile(temp_w, encoded);
    if (w32.MoveFileExW(temp_w, path_w, w32.MOVEFILE_REPLACE_EXISTING) == 0) return error.MoveFailed;
    return path;
}

fn writeFile(path: [*:0]const u16, bytes: []const u8) !void {
    const file = w32.validHandle(w32.CreateFileW(path, w32.GENERIC_WRITE, 0, null, w32.CREATE_ALWAYS, w32.FILE_ATTRIBUTE_NORMAL, null)) orelse
        return error.CreateFailed;
    defer _ = w32.CloseHandle(file);
    var left = bytes;
    while (left.len > 0) {
        var wrote: u32 = 0;
        if (w32.WriteFile(file, left.ptr, @intCast(@min(left.len, 1 << 20)), &wrote, null) == 0) return error.WriteFailed;
        left = left[wrote..];
    }
}

/// Pixel cascade: on a grid, squares that fade and thin out from the top,
/// each with its own brightness and a slow cloudiness across. The tile
/// wraps sideways without a seam.
fn drawCascade(pixels: []u8, width: u32, color: Config.Color) void {
    const c = data.pixel_cascade;
    @memset(pixels, 0);
    var row: u32 = 0;
    while (row * c.pitch < c.height) : (row += 1) {
        const y = row * c.pitch;
        const fade = std.math.pow(f32, @max(0, 1 - @as(f32, @floatFromInt(y)) / c.fade), 1.7);
        if (fade <= 0) break;
        for (0..c.columns) |col_index| {
            const col: u32 = @intCast(col_index);
            // Fewer squares survive further down.
            if (hash(col, row, 0) < (1 - fade) * 0.85) continue;
            const alpha = fade * (0.35 + 0.65 * hash(col, row, 3)) * (0.5 + 0.5 * cloud(col, row)) * c.max_alpha;
            const a: u8 = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
            if (a == 0) continue;
            for (0..c.dot) |dy| {
                if (y + dy >= c.height) break;
                for (0..c.dot) |dx| {
                    const i = ((y + dy) * width + col * c.pitch + dx) * 4;
                    pixels[i..][0..4].* = .{ color.r, color.g, color.b, a };
                }
            }
        }
    }
}

/// A stable random number in [0, 1) for a cell.
fn hash(col: u32, row: u32, seed: u32) f32 {
    var x: u32 = col *% 374761393 +% row *% 668265263 +% seed *% 2147483647;
    x = (x ^ (x >> 13)) *% 1274126177;
    return @as(f32, @floatFromInt((x ^ (x >> 16)) & 0xFFFF)) / 65535.0;
}

/// Smooth noise over an 8-cell lattice that wraps with the tile.
fn cloud(col: u32, row: u32) f32 {
    const lattice = 8;
    const across = data.pixel_cascade.columns / lattice;
    const gx = @as(f32, @floatFromInt(col)) / lattice;
    const gy = @as(f32, @floatFromInt(row)) / lattice;
    const x0: u32 = @intFromFloat(@floor(gx));
    const y0: u32 = @intFromFloat(@floor(gy));
    var fx = gx - @floor(gx);
    var fy = gy - @floor(gy);
    fx = fx * fx * (3 - 2 * fx);
    fy = fy * fy * (3 - 2 * fy);
    const v = struct {
        fn at(a: u32, b: u32) f32 {
            return hash(a % across, b, 7);
        }
    }.at;
    const top = v(x0, y0) * (1 - fx) + v(x0 + 1, y0) * fx;
    const bottom = v(x0, y0 + 1) * (1 - fx) + v(x0 + 1, y0 + 1) * fx;
    return top * (1 - fy) + bottom * fy;
}
