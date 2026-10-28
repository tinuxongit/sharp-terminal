//! Win32 input mode (mode 9001), which the bundled ConPTY asks for: key
//! and character events sent as \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences, so console
//! programs see real key events with their virtual key and scan codes.
const std = @import("std");
const input = @import("../../input.zig");
const termio = @import("../../termio.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const Surface = @import("Surface.zig");
const key_map = @import("key_map.zig");

/// Check if Win32 Input Mode is active. This mode is requested by ConPTY
/// via \x1b[?9001h and causes key events to be sent as
/// \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences.
pub fn isWin32InputMode(self: *Surface) bool {
    self.core_surface.renderer_state.mutex.lockUncancelable(global.io());
    defer self.core_surface.renderer_state.mutex.unlock(global.io());
    return self.core_surface.io.terminal.modes.get(.win32_input);
}

/// Encode and send a key event in Win32 Input Mode format.
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
pub fn sendWin32InputEvent(self: *Surface, vk: u16, lparam: isize, action: input.Action) void {
    const scancode: u16 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam & (1 << 24)) != 0;
    const repeat_count: u16 = @intCast(lparam & 0xFFFF);
    const key_down: u1 = if (action == .press or action == .repeat) 1 else 0;

    // Get the Unicode character for this key via ToUnicode. Skip
    // modifier-only keys: they never produce a character and calling
    // ToUnicode for them is one of the ways the per-thread kernel
    // keyboard state can drift over time.
    var unicode_char: u16 = 0;
    if (key_down == 1 and !key_map.isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                @intCast(scancode),
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                // Composed (or literal) char — possibly produced by
                // combining with a previously-pending dead key. Only the
                // first UTF-16 code unit is captured; supplementary-plane
                // compositions (result == 2, surrogate pair) are truncated
                // to the high surrogate. This is a Win32 Input Mode protocol
                // limitation: the Uc field is 16-bit.
                unicode_char = utf16_buf[0];
            } else if (result < 0) {
                // VK is a dead key. ToUnicode stored it in the queue's
                // dead-key state; the next press's ToUnicode call will
                // compose with it. Send Uc=0 so applications reading the
                // sequence don't see a stray dead char. The state is safe
                // to keep because App.run skips TranslateMessage for
                // surface windows — we are the only consumer.
                unicode_char = 0;
            }
        }
    }

    // Build the Win32 dwControlKeyState bitmask.
    var ctrl_state: u32 = 0;
    if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0)
        ctrl_state |= 0x0010; // SHIFT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LCONTROL)) < 0)
        ctrl_state |= 0x0008; // LEFT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0)
        ctrl_state |= 0x0004; // RIGHT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LMENU)) < 0)
        ctrl_state |= 0x0002; // LEFT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0)
        ctrl_state |= 0x0001; // RIGHT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0)
        ctrl_state |= 0x0080; // CAPSLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0)
        ctrl_state |= 0x0020; // NUMLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_SCROLL)) & 1 != 0)
        ctrl_state |= 0x0040; // SCROLLLOCK_ON
    if (extended)
        ctrl_state |= 0x0100; // ENHANCED_KEY

    writeWin32InputSequence(self, vk, scancode, unicode_char, key_down, ctrl_state, repeat_count);
}

/// Send a Win32 Input Mode event for a WM_CHAR character (IME, PostMessage, etc.)
/// These are characters without a corresponding WM_KEYDOWN, so we send a
/// synthetic key event with vk=0, sc=0.
pub fn sendWin32CharEvent(self: *Surface, char_code: u16) void {
    // Key-down event with the Unicode character
    writeWin32InputSequence(self, 0, 0, char_code, 1, 0, 1);
    // Key-up event
    writeWin32InputSequence(self, 0, 0, char_code, 0, 0, 1);
}

/// Format and write a Win32 input sequence directly to the PTY,
/// bypassing keyCallback to avoid side effects (selection clearing,
/// modifier tracking, cursor hiding, etc.).
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
pub fn writeWin32InputSequence(
    self: *Surface,
    vk: u16,
    sc: u16,
    uc: u16,
    kd: u1,
    cs: u32,
    rc: u16,
) void {
    // Keyboard, standalone WM_CHAR, and IME input all share this emitter.
    // These writes bypass the core's queueIo filter, so apply its read-only
    // policy here while allowing keybindings to run before emission.
    if (self.core_surface.readonly) return;

    var buf: [64]u8 = undefined;
    const seq = std.mem.print(&buf, "\x1b[{};{};{};{};{};{}_", .{
        vk, sc, uc, kd, cs, rc,
    }) catch return;

    // Write directly to the PTY via the IO queue.
    const msg = termio.Message.writeReq(
        self.app.core_app.alloc,
        seq,
    ) catch return;
    self.core_surface.io.queueMessage(msg, .unlocked);
}
