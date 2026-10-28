//! Input method editors (Chinese, Japanese, Korean...): the inline
//! preedit at the cursor while composing, the candidate window's place,
//! and sending the composed text to the terminal.
const std = @import("std");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32);
const Surface = @import("Surface.zig");
const win32_input = @import("win32_input.zig");

/// Handle WM_IME_STARTCOMPOSITION — an IME composition session has begun.
/// Position the candidate window near the terminal cursor and let Windows
/// show its default composition UI.
pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    // Drop any buffered high surrogate so it can't pair with IME output.
    self.high_surrogate = 0;
    positionImeWindow(self);
}

/// Handle WM_IME_ENDCOMPOSITION — the IME composition session has ended.
pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
    // Clear any leftover inline preedit (e.g. composition cancelled with Esc).
    if (self.core_surface_ready) {
        self.core_surface.preeditCallback(null) catch {};
    }
}

/// Handle WM_IME_COMPOSITION — intermediate or final text from the IME.
/// When the result string is available (GCS_RESULTSTR), extract it and
/// send it to the terminal. Returns true if we handled the result string.
pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;

    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);

    // Intermediate composition text: mirror it inline at the cursor via the
    // core's preedit (underlined, like macOS/GTK) instead of the default
    // floating composition window (suppressed via WM_IME_SETCONTEXT).
    if (flags & w32.GCS_RESULTSTR == 0) {
        if (flags & w32.GCS_COMPSTR != 0) {
            updateImePreedit(self);
            return true;
        }
        return false;
    }

    // Result string: clear the inline preedit, then commit the text below.
    self.core_surface.preeditCallback(null) catch {};

    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Query the length of the result string (in bytes).
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
    if (byte_len <= 0) return false;
    // The W variant always returns an even byte count, but reject odd
    // values defensively rather than panicking via @divExact.
    if (byte_len & 1 != 0) return false;

    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));

    // Stack buffer for typical IME results (up to 64 UTF-16 code units).
    var stack_buf: [64]u16 = undefined;

    if (u16_len <= stack_buf.len) {
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &stack_buf, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        sendImeText(self, stack_buf[0..actual_len]);
    } else {
        // Unusual: very long composition. Allocate on the heap.
        const alloc = self.app.core_app.alloc;
        const buf = alloc.alloc(u16, u16_len) catch return false;
        defer alloc.free(buf);
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, buf.ptr, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        sendImeText(self, buf[0..actual_len]);
    }

    // GCS_RESULTSTR and GCS_COMPSTR can arrive together (e.g. an IME commits
    // a syllable while starting the next). We cleared the preedit above for
    // the result; re-mirror the new composition so it isn't invisible until
    // the next keystroke.
    if (flags & w32.GCS_COMPSTR != 0) updateImePreedit(self);

    // Reposition the IME window for the next composition
    positionImeWindow(self);
    return true;
}

/// Convert a UTF-16 IME result to UTF-8 and send it to the terminal.
/// Read the current GCS_COMPSTR composition string and mirror it into the
/// core's preedit so it renders inline at the cursor. An empty composition
/// clears the preedit.
pub fn updateImePreedit(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    var buf16: [128]u16 = undefined;
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, null, 0);
    if (byte_len <= 0 or byte_len & 1 != 0) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));
    if (u16_len > buf16.len) {
        // Absurdly long composition; clear rather than truncate mid-pair.
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const got = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf16, @intCast(byte_len));
    if (got <= 0 or got & 1 != 0) return;
    const n: usize = @intCast(@divTrunc(got, 2));

    // Worst case 3 bytes of UTF-8 per UTF-16 code unit.
    var buf8: [buf16.len * 3]u8 = undefined;
    const len8 = std.unicode.utf16LeToUtf8(&buf8, buf16[0..n]) catch return;
    self.core_surface.preeditCallback(if (len8 == 0) null else buf8[0..len8]) catch |err| {
        log.warn("preeditCallback failed err={}", .{err});
    };
}

pub fn sendImeText(self: *Surface, utf16: []const u16) void {
    // In Win32 Input Mode, send each character as a Win32 input event
    // so ConPTY can reconstruct the full Unicode codepoints.
    if (win32_input.isWin32InputMode(self)) {
        for (utf16) |code_unit| {
            win32_input.sendWin32CharEvent(self, code_unit);
        }
        return;
    }

    // A UTF-16 unit becomes at most 3 bytes of UTF-8, and the conversion
    // doesn't bounds-check. Long results (the heap path in
    // handleImeComposition) get a buffer of their own.
    var stack_buf: [256]u8 = undefined;
    const alloc = self.app.core_app.alloc;
    const utf8_buf = if (utf16.len * 3 <= stack_buf.len)
        stack_buf[0..]
    else
        alloc.alloc(u8, utf16.len * 3) catch return;
    defer if (utf8_buf.ptr != &stack_buf) alloc.free(utf8_buf);
    const len = std.unicode.utf16LeToUtf8(utf8_buf, utf16) catch |err| {
        log.warn("IME utf16→utf8 error: {}", .{err});
        return;
    };
    if (len == 0) return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("IME text callback error: {}", .{err});
    };
}

/// Position the IME candidate/composition window near the terminal cursor.
pub fn positionImeWindow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Use the core surface's imePoint() which calculates the cursor
    // position in pixels from the terminal grid, accounting for padding
    // and content scale.
    var pos = w32.POINT{ .x = 0, .y = 0 };
    if (self.core_surface_ready) {
        const ime_pos = self.core_surface.imePoint();
        pos.x = @intFromFloat(ime_pos.x);
        pos.y = @intFromFloat(ime_pos.y);
    }

    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = pos,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}
