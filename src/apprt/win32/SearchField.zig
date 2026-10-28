//! A one-line search box for Sharp's own UI (the settings panel and the
//! tab sidebar): the text typed so far, its focus and blinking caret, and
//! how it is drawn. The caret always sits at the end of the text.
const SearchField = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

buf: [64]u8 = undefined,
len: usize = 0,
focused: bool = false,
caret_visible: bool = true,

/// Timer id the field blinks its caret with on the owning window.
pub const caret_timer: usize = 0x5346;

const icon_search = 0xE721;

pub fn text(self: *const SearchField) []const u8 {
    return self.buf[0..self.len];
}

pub fn clear(self: *SearchField) void {
    self.len = 0;
}

/// Take or release keyboard focus. The caret blinks on `hwnd`'s timer,
/// whose WM_TIMER the owner forwards to blink().
pub fn focus(self: *SearchField, hwnd: w32.HWND, focused: bool) void {
    self.focused = focused;
    self.caret_visible = true;
    if (focused) {
        _ = w32.SetTimer(hwnd, caret_timer, w32.GetCaretBlinkTime(), null);
    } else {
        _ = w32.KillTimer(hwnd, caret_timer);
    }
}

pub fn blink(self: *SearchField) void {
    self.caret_visible = !self.caret_visible;
}

/// Add a typed character. Returns whether the text changed.
pub fn typeChar(self: *SearchField, char: u16) bool {
    if (char < 0x20 or char == 0x7F or (char >= 0xD800 and char <= 0xDFFF)) return false;
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(char, &utf8) catch return false;
    if (self.len + n > self.buf.len) return false;
    @memcpy(self.buf[self.len..][0..n], utf8[0..n]);
    self.len += n;
    self.caret_visible = true;
    return true;
}

/// Handle an editing key from WM_KEYDOWN: Backspace, and Ctrl+V to paste
/// the clipboard's first line. Returns whether the text changed.
pub fn key(self: *SearchField, hwnd: w32.HWND, vk: u16) bool {
    switch (vk) {
        w32.VK_BACK => {
            if (self.len == 0) return false;
            // Drop one whole UTF-8 character.
            var i = self.len - 1;
            while (i > 0 and self.buf[i] & 0xC0 == 0x80) i -= 1;
            self.len = i;
            self.caret_visible = true;
            return true;
        },
        'V' => {
            if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) >= 0) return false;
            if (w32.OpenClipboard(hwnd) == 0) return false;
            defer _ = w32.CloseClipboard();
            const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return false;
            const bytes = w32.GlobalLock(handle) orelse return false;
            defer _ = w32.GlobalUnlock(handle);
            const pasted: [*:0]const u16 = @ptrCast(@alignCast(bytes));
            var i: usize = 0;
            var changed = false;
            while (pasted[i] != 0 and pasted[i] != '\r' and pasted[i] != '\n') : (i += 1) {
                if (!self.typeChar(pasted[i])) break;
                changed = true;
            }
            return changed;
        },
        else => return false,
    }
}

/// Whether `haystack` contains `needle`, ignoring ASCII case.
pub fn matches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub const Look = struct {
    fill: Rgb,
    hover: Rgb,
    focused: Rgb,
    text: Rgb,
    text_dim: Rgb,
    font: ?*anyopaque,
    icon_font: ?*anyopaque,
    placeholder: []const u8,
};

/// Draw the field. `window_focused` hides the caret while another window
/// has the keyboard.
pub fn paint(self: *const SearchField, c: Canvas, rect: w32.RECT, scale: f32, look: Look, hovered: bool, window_focused: bool) void {
    const px = struct {
        fn f(v: f32, s: f32) i32 {
            return @intFromFloat(@round(v * s));
        }
    }.f;
    const fill = if (self.focused) look.focused else if (hovered) look.hover else look.fill;
    c.fillRounded(rect, px(8, scale), fill);
    c.glyph(.{ .left = rect.left + px(8, scale), .top = rect.top, .right = rect.left + px(30, scale), .bottom = rect.bottom }, icon_search, look.icon_font, look.text_dim);

    const text_rect: w32.RECT = .{ .left = rect.left + px(36, scale), .top = rect.top, .right = rect.right - px(8, scale), .bottom = rect.bottom };
    if (self.len > 0) {
        c.text(text_rect, self.text(), look.font, look.text, .left);
    } else {
        c.text(text_rect, look.placeholder, look.font, look.text_dim, .left);
    }
    if (self.focused and window_focused and self.caret_visible) {
        // With no text the caret sits just before the placeholder.
        const after = if (self.len > 0) c.textWidth(self.text(), look.font) + 1 else -px(3, scale);
        const x = @min(text_rect.left + after, text_rect.right);
        const h = px(16, scale);
        const top = rect.top + @divTrunc(rect.bottom - rect.top - h, 2);
        c.fill(.{ .left = x, .top = top, .right = x + @max(1, px(1, scale)), .bottom = top + h }, look.text);
    }
}
