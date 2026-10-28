//! Renaming a tab or the window in place: an edit box over the tab's
//! title, committed on Enter or losing focus and dropped on Escape.
const std = @import("std");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");

/// Rename edit control child ID.
pub const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    // Cancel any existing rename
    cancelTabRename(self);
    self.rename_window = false;

    const hwnd = self.hwnd orelse return;
    const rect = rect: {
        if (self.tab_bar_visible) break :rect self.stripLayout().tabRect(tab_idx);

        // A single-tab window has no tab bar. Use a compact editor at the
        // top of the client area so prompt_*_title remains usable.
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        break :rect w32.RECT{
            .left = 8,
            .top = 8,
            .right = @max(168, client.right - 8),
            .bottom = 38,
        };
    };

    // tab_titles stores only `tab_title_lens` valid u16s; the rest is
    // uninitialized. CreateWindowExW reads a NUL-terminated wide string,
    // so a NUL-terminated copy avoids the Edit displaying garbage past
    // the real title.
    var title_buf: [257]u16 = undefined;
    const tlen = self.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], self.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}

/// Prompt for an explicit top-level window title using the same lightweight
/// inline editor as tab renaming.
pub fn startWindowRename(self: *Window) void {
    startTabRename(self, self.active_tab);
    const edit = self.rename_edit orelse return;
    self.rename_window = true;

    var title: [257]u16 = undefined;
    const len: usize = if (self.window_title_override_len) |override_len| len: {
        @memcpy(title[0..override_len], self.window_title_override[0..override_len]);
        break :len override_len;
    } else @intCast(w32.GetWindowTextW(self.hwnd.?, &title, 256));
    title[len] = 0;
    _ = w32.SetWindowTextW(edit, @ptrCast(&title));
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
}

/// Apply the edit text as the new tab title and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (self.rename_window) {
        if (wlen == 0) {
            self.window_title_override_len = null;
        } else {
            const len: u16 = @intCast(@min(wlen, 255));
            @memcpy(self.window_title_override[0..len], wbuf[0..len]);
            self.window_title_override_len = len;
        }
        self.updateWindowTitle();
    } else if (wlen > 0) {
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    self.rename_window = false;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();

    // Return focus to the active surface
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        self.rename_window = false;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActiveSurface()) |s| {
            if (s.hwnd) |h| _ = w32.SetFocus(h);
        }
    }
}
