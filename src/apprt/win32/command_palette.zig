//! The command palette of a terminal pane (Ctrl+Shift+P): the actions it
//! offers, the popup that filters them as you type, its painting with
//! each action's shortcut, and running the chosen one.
const std = @import("std");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const find_bar = @import("find_bar.zig");
const log = std.log.scoped(.win32);
const Surface = @import("Surface.zig");

/// A command palette entry: display name + the binding action to execute.
pub const PaletteEntry = struct {
    name: []const u8,
    action: input.Binding.Action,
};

/// Cap on user-configured command-palette-entry commands shown in the
/// palette (bounds the fixed-size palette_filtered index array).
pub const MAX_USER_PALETTE_ENTRIES = 64;

/// Palette indexes >= palette_entries.len refer to user-configured
/// command-palette-entry commands from the config, in order.
pub fn paletteEntryName(self: *const Surface, idx: u16) []const u8 {
    if (idx < palette_entries.len) return palette_entries[idx].name;
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return "";
    return user[uidx].title;
}

pub fn paletteEntryAction(self: *const Surface, idx: u16) ?input.Binding.Action {
    if (idx < palette_entries.len) return palette_entries[idx].action;
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return null;
    return user[uidx].action;
}

/// Child window ID for the palette edit control.
pub const PALETTE_EDIT_ID: u16 = 200;

/// Layout constants for the palette list (unscaled, multiply by self.scale).
pub const PALETTE_LIST_TOP: f32 = 40.0;
pub const PALETTE_ITEM_HEIGHT: f32 = 28.0;

/// Static list of commands shown in the palette.
pub const palette_entries = [_]PaletteEntry{
    .{ .name = "New Window", .action = .new_window },
    .{ .name = "New Tab", .action = .new_tab },
    .{ .name = "Tab Overview", .action = .toggle_tab_overview },
    .{ .name = "Close Surface", .action = .close_surface },
    .{ .name = "Close Tab", .action = .{ .close_tab = .this } },
    .{ .name = "Close Window", .action = .close_window },
    .{ .name = "Reopen Closed Tab", .action = .undo },
    .{ .name = "Previous Tab", .action = .previous_tab },
    .{ .name = "Next Tab", .action = .next_tab },
    .{ .name = "Last Tab", .action = .last_tab },
    .{ .name = "Split Right", .action = .{ .new_split = .right } },
    .{ .name = "Split Down", .action = .{ .new_split = .down } },
    .{ .name = "Split Left", .action = .{ .new_split = .left } },
    .{ .name = "Split Up", .action = .{ .new_split = .up } },
    .{ .name = "Focus Split Right", .action = .{ .goto_split = .right } },
    .{ .name = "Focus Split Down", .action = .{ .goto_split = .down } },
    .{ .name = "Focus Split Left", .action = .{ .goto_split = .left } },
    .{ .name = "Focus Split Up", .action = .{ .goto_split = .up } },
    .{ .name = "Focus Previous Split", .action = .{ .goto_split = .previous } },
    .{ .name = "Focus Next Split", .action = .{ .goto_split = .next } },
    .{ .name = "Toggle Split Zoom", .action = .toggle_split_zoom },
    .{ .name = "Equalize Splits", .action = .equalize_splits },
    .{ .name = "Swap Split with Next", .action = .{ .split_pane = .swap_next } },
    .{ .name = "Swap Split with Previous", .action = .{ .split_pane = .swap_previous } },
    .{ .name = "Flip Split Orientation", .action = .{ .split_pane = .flip } },
    .{ .name = "Move Split to New Tab", .action = .{ .split_pane = .to_new_tab } },
    .{ .name = "Close Other Splits", .action = .{ .split_pane = .close_others } },
    .{ .name = "Toggle Broadcast Input", .action = .{ .split_pane = .broadcast } },
    .{ .name = "Toggle Fullscreen", .action = .toggle_fullscreen },
    .{ .name = "Toggle Maximize", .action = .toggle_maximize },
    .{ .name = "Toggle Window Decorations", .action = .toggle_window_decorations },
    .{ .name = "Toggle Background Opacity", .action = .toggle_background_opacity },
    .{ .name = "Toggle Quick Terminal", .action = .toggle_quick_terminal },
    .{ .name = "Toggle Read-Only", .action = .toggle_readonly },
    .{ .name = "Toggle Mouse Reporting", .action = .toggle_mouse_reporting },
    .{ .name = "Reset Mouse Reporting", .action = .reset_mouse_reporting },
    .{ .name = "Copy to Clipboard", .action = .{ .copy_to_clipboard = .mixed } },
    .{ .name = "Paste from Clipboard", .action = .paste_from_clipboard },
    .{ .name = "Copy URL to Clipboard", .action = .copy_url_to_clipboard },
    .{ .name = "Copy Title to Clipboard", .action = .copy_title_to_clipboard },
    .{ .name = "Select All", .action = .select_all },
    .{ .name = "Mark Mode", .action = .{ .sharp = .mark_mode } },
    .{ .name = "Toggle Block Selection", .action = .{ .sharp = .block_selection } },
    .{ .name = "Search the Web", .action = .{ .sharp = .search_web } },
    .{ .name = "Open Folder in Explorer", .action = .{ .sharp = .open_folder } },
    .{ .name = "Find", .action = .start_search },
    .{ .name = "Search Selection", .action = .search_selection },
    .{ .name = "Increase Font Size", .action = .{ .increase_font_size = 1 } },
    .{ .name = "Decrease Font Size", .action = .{ .decrease_font_size = 1 } },
    .{ .name = "Reset Font Size", .action = .reset_font_size },
    .{ .name = "Scroll Page Up", .action = .scroll_page_up },
    .{ .name = "Scroll Page Down", .action = .scroll_page_down },
    .{ .name = "Scroll to Top", .action = .scroll_to_top },
    .{ .name = "Scroll to Bottom", .action = .scroll_to_bottom },
    .{ .name = "Clear Screen", .action = .clear_screen },
    .{ .name = "Reset Terminal", .action = .reset },
    .{ .name = "Open Config", .action = .{ .open_config = .default } },
    .{ .name = "Reload Config", .action = .reload_config },
    .{ .name = "Quit", .action = .quit },
};

/// Toggle the command palette visibility.
pub fn setCommandPaletteActive(self: *Surface, active: bool) void {
    if (active) {
        // Close search bar if open (mutual exclusion)
        if (self.search_active) {
            find_bar.setSearchActive(self, false, &[_:0]u8{});
        }
        self.palette_active = true;
        ensureCommandPalette(self);
        if (self.palette_hwnd) |popup| {
            positionCommandPalette(self);
            filterPaletteEntries(self, "");
            _ = w32.ShowWindow(popup, w32.SW_SHOW);
            if (self.palette_edit) |edit| {
                _ = w32.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.palette_active = false;
        if (self.palette_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0); // SW_HIDE
        }
        if (self.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}

/// Create the command palette popup if it doesn't exist.
pub fn ensureCommandPalette(self: *Surface) void {
    if (self.palette_hwnd != null) return;

    const s = self.scale;
    const pal_w: i32 = @intFromFloat(@round(500.0 * s));
    const pal_h: i32 = @intFromFloat(@round(450.0 * s));
    const pad: i32 = @intFromFloat(@round(8.0 * s));
    const edit_h: i32 = @intFromFloat(@round(24.0 * s));

    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        pal_w,
        pal_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the search edit at the top (DPI-scaled)
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        pal_w - pad * 2 - 2,
        edit_h,
        popup,
        @ptrFromInt(@as(usize, PALETTE_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Set font (DPI-scaled) — stored for cleanup in deinit
    self.palette_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
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
    if (self.palette_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Create cached brush for WM_CTLCOLOREDIT (avoids leak on every repaint)
    self.palette_brush = w32.CreateSolidBrush(w32.RGB(30, 30, 30));

    // Set placeholder text via EM_SETCUEBANNER
    const placeholder = std.unicode.utf8ToUtf16LeStringLiteral("Type a command...");
    _ = w32.SendMessageW(edit, 0x1501, 1, @bitCast(@intFromPtr(placeholder))); // EM_SETCUEBANNER

    // Store surface pointer for message routing
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.palette_hwnd = popup;
    self.palette_edit = edit;
}

/// Position the command palette centered at the top of the parent window.
pub fn positionCommandPalette(self: *Surface) void {
    const popup = self.palette_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const win_width = rect.right - rect.left;
        const pal_width: i32 = @intFromFloat(@round(500.0 * s));
        const pal_height: i32 = @intFromFloat(@round(450.0 * s));
        const title_bar: i32 = @intFromFloat(@round(40.0 * s));
        const x = rect.left + @divTrunc(win_width - pal_width, 2);
        const y = rect.top + title_bar;
        _ = w32.MoveWindow(popup, x, y, pal_width, pal_height, 1);
    }
}

/// Filter palette entries by a case-insensitive substring match.
pub fn filterPaletteEntries(self: *Surface, filter: []const u8) void {
    var count: u16 = 0;
    for (palette_entries, 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.findIgnoreCase(entry.name, filter) != null) {
            self.palette_filtered[count] = @intCast(i);
            count += 1;
        }
    }
    // User-configured command-palette-entry commands, appended after the
    // built-in entries.
    const user = self.app.config.@"command-palette-entry".value.items;
    const user_len = @min(user.len, MAX_USER_PALETTE_ENTRIES);
    for (user[0..user_len], 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.findIgnoreCase(entry.title, filter) != null) {
            self.palette_filtered[count] = @intCast(palette_entries.len + i);
            count += 1;
        }
    }
    self.palette_count = count;
    self.palette_selected = 0;
    // Trigger repaint of the list area
    if (self.palette_hwnd) |popup| {
        _ = w32.InvalidateRect(popup, null, 1);
    }
}

/// Handle text changes in the palette search edit (EN_CHANGE).
pub fn handlePaletteChange(self: *Surface) void {
    const edit = self.palette_edit orelse return;

    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));

    var utf8_buf: [512]u8 = undefined;
    const utf8_len = wide_string.toUtf8(&utf8_buf, wbuf[0..wlen]);

    filterPaletteEntries(self, utf8_buf[0..utf8_len]);
}

/// Handle key events in the command palette. Returns true if handled.
pub fn handlePaletteKey(self: *Surface, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            setCommandPaletteActive(self, false);
            return true;
        },
        w32.VK_RETURN => {
            executePaletteSelection(self);
            return true;
        },
        w32.VK_UP => {
            if (self.palette_selected > 0) {
                self.palette_selected -= 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        w32.VK_DOWN => {
            if (self.palette_count > 0 and self.palette_selected < self.palette_count - 1) {
                self.palette_selected += 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        else => return false,
    }
}

/// Execute the currently selected palette entry.
pub fn executePaletteSelection(self: *Surface) void {
    if (!self.core_surface_ready) return;
    if (self.palette_selected >= self.palette_count) return;

    const entry_idx = self.palette_filtered[self.palette_selected];
    const action = paletteEntryAction(self, entry_idx) orelse return;

    // Close the palette first
    setCommandPaletteActive(self, false);

    // Execute the action
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.err("palette action error: {}", .{err});
    };
}

/// Paint the command palette list area.
pub fn paintPalette(self: *Surface, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;

    // Fill background. Reuse the cached brush set up by setCommandPaletteActive
    // — falling back to a one-shot brush only if it's somehow missing.
    if (self.palette_brush) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
    } else if (w32.CreateSolidBrush(w32.RGB(30, 30, 30))) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
        _ = w32.DeleteObject(b);
    }

    // Reuse a cached 14pt font; create on first paint and keep it for
    // the lifetime of this popup. Rebuilt by handleDpiChange.
    const s = self.scale;
    if (self.palette_paint_font == null) {
        self.palette_paint_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(14.0 * s))),
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
    }
    const old_font = if (self.palette_paint_font) |f| w32.SelectObject(hdc, f) else null;
    defer {
        if (old_font) |of| _ = w32.SelectObject(hdc, of);
    }

    _ = w32.SetBkMode(hdc, 1); // TRANSPARENT

    const item_height: i32 = @intFromFloat(@round(PALETTE_ITEM_HEIGHT * s));
    const list_top: i32 = @intFromFloat(@round(PALETTE_LIST_TOP * s));
    const max_visible = @divTrunc(client_rect.bottom - list_top, item_height);
    if (max_visible <= 0) return; // popup too small to render any items

    // Calculate scroll offset to keep selected item visible
    var scroll_offset: i32 = 0;
    if (self.palette_selected >= max_visible) {
        scroll_offset = self.palette_selected - @as(u16, @intCast(max_visible)) + 1;
    }

    var i: u16 = 0;
    while (i < self.palette_count) : (i += 1) {
        const visual_idx = @as(i32, i) - scroll_offset;
        if (visual_idx < 0) continue;
        if (visual_idx >= max_visible) break;

        const y = list_top + visual_idx * item_height;
        const entry_idx = self.palette_filtered[i];
        const entry_name = paletteEntryName(self, entry_idx);
        const entry_action = paletteEntryAction(self, entry_idx);

        // Draw selection highlight
        if (i == self.palette_selected) {
            if (w32.CreateSolidBrush(w32.RGB(60, 60, 80))) |sel_brush| {
                const sel_rect = w32.RECT{
                    .left = 0,
                    .top = y,
                    .right = client_rect.right,
                    .bottom = y + item_height,
                };
                _ = w32.FillRect(hdc, &sel_rect, sel_brush);
                _ = w32.DeleteObject(sel_brush);
            }
        }

        // Draw action name
        const text_pad: i32 = @intFromFloat(@round(12.0 * s));
        const text_top_pad: i32 = @intFromFloat(@round(4.0 * s));
        const kb_area: i32 = @intFromFloat(@round(160.0 * s));
        _ = w32.SetTextColor(hdc, w32.RGB(220, 220, 220));
        var name_rect = w32.RECT{
            .left = text_pad,
            .top = y + text_top_pad,
            .right = client_rect.right - kb_area,
            .bottom = y + item_height,
        };
        var wname_buf: [128]u16 = undefined;
        // User-configured palette titles are arbitrary length; cap to the
        // buffer (N UTF-8 bytes ≤ N UTF-16 units) on a codepoint boundary so
        // a long title truncates instead of overflowing the stack buffer.
        var name_len = @min(entry_name.len, wname_buf.len);
        while (name_len > 0 and entry_name[name_len - 1] & 0xC0 == 0x80) name_len -= 1;
        const wname_len = std.unicode.utf8ToUtf16Le(&wname_buf, entry_name[0..name_len]) catch 0;
        _ = w32.DrawTextW(hdc, @ptrCast(&wname_buf), @intCast(wname_len), &name_rect, 0);

        // Draw keybinding hint on the right
        const trigger = if (entry_action) |a| self.app.config.keybind.set.getTrigger(a) else null;
        if (trigger) |t| {
            _ = w32.SetTextColor(hdc, w32.RGB(140, 140, 140));
            var kb_buf: [64]u8 = undefined;
            const kb_len = formatTrigger(t, &kb_buf);
            var wkb_buf: [64]u16 = undefined;
            const wkb_len = std.unicode.utf8ToUtf16Le(&wkb_buf, kb_buf[0..kb_len]) catch 0;
            var kb_rect = w32.RECT{
                .left = client_rect.right - kb_area + text_top_pad,
                .top = y + text_top_pad,
                .right = client_rect.right - text_pad,
                .bottom = y + item_height,
            };
            _ = w32.DrawTextW(hdc, @ptrCast(&wkb_buf), @intCast(wkb_len), &kb_rect, 0x0002); // DT_RIGHT
        }
    }
}

/// Format a keybinding trigger as a human-readable string (e.g. "Ctrl+Shift+T").
pub fn formatTrigger(trigger: input.Binding.Trigger, buf: []u8) usize {
    var pos: usize = 0;

    if (trigger.mods.super) {
        const s = "Win+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.ctrl) {
        const s = "Ctrl+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.alt) {
        const s = "Alt+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.shift) {
        const s = "Shift+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }

    switch (trigger.key) {
        .unicode => |cp| {
            // Convert to upper-case letter for display
            if (cp >= 'a' and cp <= 'z') {
                buf[pos] = @intCast(cp - 32);
                pos += 1;
            } else if (cp >= ' ' and cp <= '~') {
                buf[pos] = @intCast(cp);
                pos += 1;
            }
        },
        .physical => |k| {
            const name = keyName(k);
            if (name.len > 0 and pos + name.len <= buf.len) {
                @memcpy(buf[pos..][0..name.len], name);
                pos += name.len;
            }
        },
        .catch_all => {},
    }

    return pos;
}

/// Map physical key enum to display name.
pub fn keyName(k: input.Key) []const u8 {
    return switch (k) {
        .key_a => "A",
        .key_b => "B",
        .key_c => "C",
        .key_d => "D",
        .key_e => "E",
        .key_f => "F",
        .key_g => "G",
        .key_h => "H",
        .key_i => "I",
        .key_j => "J",
        .key_k => "K",
        .key_l => "L",
        .key_m => "M",
        .key_n => "N",
        .key_o => "O",
        .key_p => "P",
        .key_q => "Q",
        .key_r => "R",
        .key_s => "S",
        .key_t => "T",
        .key_u => "U",
        .key_v => "V",
        .key_w => "W",
        .key_x => "X",
        .key_y => "Y",
        .key_z => "Z",
        .digit_0 => "0",
        .digit_1 => "1",
        .digit_2 => "2",
        .digit_3 => "3",
        .digit_4 => "4",
        .digit_5 => "5",
        .digit_6 => "6",
        .digit_7 => "7",
        .digit_8 => "8",
        .digit_9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        else => "",
    };
}
