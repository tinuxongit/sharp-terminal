//! Drawing for Sharp's own UI (tab strip, settings panel): a 32-bit DIB
//! that GDI draws text into and that anti-aliased shapes are blended into
//! directly, since GDI's own rounded shapes are jagged.
const std = @import("std");
const w32 = @import("win32.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };

    pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        const lerp = struct {
            fn f(x: u8, y: u8, k: f32) u8 {
                const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
                return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
            }
        }.f;
        return .{ .r = lerp(a.r, b.r, t), .g = lerp(a.g, b.g, t), .b = lerp(a.b, b.b, t) };
    }

    pub fn isDark(self: Rgb) bool {
        const luminance = 0.2126 * @as(f32, @floatFromInt(self.r)) +
            0.7152 * @as(f32, @floatFromInt(self.g)) +
            0.0722 * @as(f32, @floatFromInt(self.b));
        return luminance < 128;
    }

    /// GDI's COLORREF order.
    pub fn ref(self: Rgb) u32 {
        return w32.RGB(self.r, self.g, self.b);
    }

    /// A 32-bit DIB pixel stores blue in the low byte.
    pub fn toPixel(self: Rgb) u32 {
        return @as(u32, self.b) | (@as(u32, self.g) << 8) | (@as(u32, self.r) << 16);
    }

    pub fn fromPixel(p: u32) Rgb {
        return .{ .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p) };
    }
};

/// A top-down 32-bit DIB selected into `hdc`.
pub const Canvas = struct {
    hdc: w32.HDC,
    pixels: [*]u32,
    width: i32,
    height: i32,

    /// Direct pixel access must wait for GDI's queued drawing.
    pub fn sync(_: Canvas) void {
        _ = w32.GdiFlush();
    }

    pub fn blend(self: Canvas, x: i32, y: i32, color: Rgb, coverage: f32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height or coverage <= 0) return;
        const p = &self.pixels[@intCast(y * self.width + x)];
        p.* = if (coverage >= 1) color.toPixel() else Rgb.fromPixel(p.*).mix(color, coverage).toPixel();
    }

    pub fn fill(self: Canvas, rect: w32.RECT, color: Rgb) void {
        const left = @max(rect.left, 0);
        const right = @min(rect.right, self.width);
        if (right <= left) return;
        const pixel = color.toPixel();
        var y = @max(rect.top, 0);
        while (y < @min(rect.bottom, self.height)) : (y += 1) {
            const row: usize = @intCast(y * self.width);
            @memset(self.pixels[row + @as(usize, @intCast(left)) .. row + @as(usize, @intCast(right))], pixel);
        }
    }

    /// Fill a rounded rectangle; a radius of half the size draws a circle.
    pub fn fillRounded(self: Canvas, rect: w32.RECT, radius: i32, color: Rgb) void {
        const r = @max(0, @min(radius, @divTrunc(rect.right - rect.left, 2), @divTrunc(rect.bottom - rect.top, 2)));
        self.fill(.{ .left = rect.left + r, .top = rect.top, .right = rect.right - r, .bottom = rect.bottom }, color);
        self.fill(.{ .left = rect.left, .top = rect.top + r, .right = rect.left + r, .bottom = rect.bottom - r }, color);
        self.fill(.{ .left = rect.right - r, .top = rect.top + r, .right = rect.right, .bottom = rect.bottom - r }, color);
        self.corner(rect.left, rect.top, r, .{ 1, 1 }, .inside, color);
        self.corner(rect.right - r, rect.top, r, .{ 0, 1 }, .inside, color);
        self.corner(rect.left, rect.bottom - r, r, .{ 1, 0 }, .inside, color);
        self.corner(rect.right - r, rect.bottom - r, r, .{ 0, 0 }, .inside, color);
    }

    /// A rounded rectangle with a one-pixel border.
    pub fn fillBordered(self: Canvas, rect: w32.RECT, radius: i32, color: Rgb, border: Rgb) void {
        self.fillRounded(rect, radius, border);
        self.fillRounded(.{ .left = rect.left + 1, .top = rect.top + 1, .right = rect.right - 1, .bottom = rect.bottom - 1 }, radius - 1, color);
    }

    pub const Side = enum { inside, outside };

    /// Blend an r×r square at (x0, y0) by how much of each pixel lies
    /// inside (or outside) a quarter circle. `center` says which corner of
    /// the square the circle's center sits on (1 = far side on that axis).
    pub fn corner(self: Canvas, x0: i32, y0: i32, r: i32, center: [2]u1, side: Side, color: Rgb) void {
        if (r <= 0) return;
        var py: i32 = 0;
        while (py < r) : (py += 1) {
            var px_: i32 = 0;
            while (px_ < r) : (px_ += 1) {
                const inside = cornerCoverage(px_, py, r, center);
                self.blend(x0 + px_, y0 + py, color, if (side == .inside) inside else 1 - inside);
            }
        }
    }

    /// Fade the right end of `rect` into `background`, Chrome's way of
    /// cutting text that doesn't fit instead of an ellipsis.
    pub fn fadeRight(self: Canvas, rect: w32.RECT, width: i32, background: Rgb) void {
        const w = @min(width, rect.right - rect.left);
        if (w <= 0) return;
        var x = rect.right - w;
        while (x < rect.right) : (x += 1) {
            const t = @as(f32, @floatFromInt(x - (rect.right - w) + 1)) / @as(f32, @floatFromInt(w));
            var y = rect.top;
            while (y < rect.bottom) : (y += 1) self.blend(x, y, background, t);
        }
    }

    pub const Align = enum { left, center, right };

    /// Draw one line of UTF-8 text, vertically centered in `rect` and cut
    /// with an ellipsis if it doesn't fit.
    pub fn text(self: Canvas, rect: w32.RECT, utf8: []const u8, font: ?*anyopaque, color: Rgb, alignment: Align) void {
        var buf: [256]u16 = undefined;
        const len = utf16(&buf, utf8);
        self.textWide(rect, buf[0..len], font, color, alignment, w32.DT_END_ELLIPSIS);
    }

    /// Draw a single icon glyph centered in `rect`.
    pub fn glyph(self: Canvas, rect: w32.RECT, code: u16, font: ?*anyopaque, color: Rgb) void {
        self.textWide(rect, &.{code}, font, color, .center, 0);
    }

    pub fn textWide(self: Canvas, rect: w32.RECT, wide: []const u16, font: ?*anyopaque, color: Rgb, alignment: Align, extra: u32) void {
        if (wide.len == 0 or rect.right <= rect.left) return;
        _ = w32.SelectObject(self.hdc, font);
        _ = w32.SetTextColor(self.hdc, color.ref());
        _ = w32.SetBkMode(self.hdc, w32.TRANSPARENT);
        const horizontal: u32 = switch (alignment) {
            .left => w32.DT_LEFT,
            .center => w32.DT_CENTER,
            .right => w32.DT_RIGHT,
        };
        var r = rect;
        _ = w32.DrawTextW(self.hdc, wide.ptr, @intCast(wide.len), &r, horizontal | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX | extra);
    }

    /// Width in pixels of `utf8` drawn in `font`.
    pub fn textWidth(self: Canvas, utf8: []const u8, font: ?*anyopaque) i32 {
        var buf: [256]u16 = undefined;
        const len = utf16(&buf, utf8);
        _ = w32.SelectObject(self.hdc, font);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(self.hdc, &buf, @intCast(len), &size);
        return size.cx;
    }
};

fn utf16(buf: []u16, utf8: []const u8) usize {
    return @import("wide_string.zig").fromUtf8(buf, utf8);
}

/// How much of pixel (px, py) in an r×r square lies inside the quarter
/// circle of radius r centered on the square's `center` corner, from 4×4
/// samples.
pub fn cornerCoverage(px: i32, py: i32, r: i32, center: [2]u1) f32 {
    const rf: f32 = @floatFromInt(r);
    const cx: f32 = if (center[0] == 1) rf else 0;
    const cy: f32 = if (center[1] == 1) rf else 0;
    const samples = 4;
    var inside: u32 = 0;
    for (0..samples) |sy| {
        for (0..samples) |sx| {
            const fx = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples - cx;
            const fy = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples - cy;
            if (fx * fx + fy * fy <= rf * rf) inside += 1;
        }
    }
    return @as(f32, @floatFromInt(inside)) / (samples * samples);
}

pub const Quality = enum(u32) {
    /// For text.
    cleartype = 5,
    /// For icons: ClearType's colored subpixels show as tinted fringes on
    /// thin glyphs, so Windows draws its own caption icons in grayscale.
    grayscale = 4,
};

pub fn createFont(size: f32, scale: f32, face: [*:0]const u16, weight: i32, quality: Quality) ?*anyopaque {
    return w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(size * scale))),
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        @backingInt(quality),
        0,
        face,
    );
}

pub const segoe_ui = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

/// Windows 11 ships Segoe Fluent Icons; Windows 10 only has Segoe MDL2
/// Assets, which uses the same code points. A missing font would silently
/// fall back to one that draws boxes, so check what Windows picked.
pub fn iconFace(hdc: w32.HDC) [*:0]const u16 {
    const fluent = std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons");
    const mdl2 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets");
    const probe = createFont(10, 1, fluent, w32.FW_NORMAL, .grayscale) orelse return mdl2;
    defer _ = w32.DeleteObject(probe);
    const old = w32.SelectObject(hdc, probe);
    defer _ = w32.SelectObject(hdc, old);
    var face: [32]u16 = undefined;
    const len = w32.GetTextFaceW(hdc, face.len, &face);
    if (len <= 0) return mdl2;
    const picked = face[0..@min(@as(usize, @intCast(len)), face.len)];
    const expected: []const u16 = fluent;
    return if (std.mem.startsWith(u16, picked, expected)) fluent else mdl2;
}

/// Sharp's own UI text uses the terminal's default font, JetBrains Mono,
/// which Ghostty embeds. Windows can't use it until it is registered;
/// AddFontMemResourceEx keeps it private to this process.
pub const jetbrains_mono = std.unicode.utf8ToUtf16LeStringLiteral("JetBrains Mono");

pub const EmbeddedFonts = [2]?w32.HANDLE;

pub fn loadEmbeddedFonts() EmbeddedFonts {
    const embedded = @import("../../font/main.zig").embedded;
    var result: EmbeddedFonts = .{ null, null };
    inline for (.{ embedded.regular, embedded.bold }, 0..) |file, i| {
        var count: u32 = 0;
        result[i] = w32.AddFontMemResourceEx(file.ptr, file.len, null, &count);
    }
    return result;
}

pub fn unloadEmbeddedFonts(fonts: EmbeddedFonts) void {
    for (fonts) |font| {
        if (font) |h| _ = w32.RemoveFontMemResourceEx(h);
    }
}
