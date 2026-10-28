//! The mouse over a terminal pane: buttons, moves and wheel passed to the
//! core, the pointer's shape, the link preview at the bottom, the
//! right-click menu, and files dropped from Explorer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const w32 = @import("win32.zig");
const clipboard = @import("clipboard.zig");
const key_map = @import("key_map.zig");
const profiles = @import("profiles.zig");
const log = std.log.scoped(.win32);
const Surface = @import("Surface.zig");

/// Release pointer capture when recovering from an interrupted mouse session.
pub fn cancelMouseCapture(self: *Surface) void {
    if (self.mouse_button_mask == 0) return;
    self.mouse_button_mask = 0;
    _ = w32.ReleaseCapture();
}

/// Handle WM_LBUTTONDOWN / WM_RBUTTONDOWN / WM_MBUTTONDOWN /
/// WM_LBUTTONUP / WM_RBUTTONUP / WM_MBUTTONUP.
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = key_map.getModifiers();

    // Capture mouse on the first pressed button; release only when all
    // buttons are up. Otherwise a right-click in the middle of a left-
    // button drag clobbers capture, and the next up-event releases it
    // for everyone.
    const bit: u3 = switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
        else => 0,
    };
    if (bit != 0) {
        const prev = self.mouse_button_mask;
        if (action == .press) {
            self.mouse_button_mask |= bit;
            if (prev == 0) {
                if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
            }
        } else {
            self.mouse_button_mask &= ~bit;
            if (prev != 0 and self.mouse_button_mask == 0) {
                _ = w32.ReleaseCapture();
            }
        }
    }

    // Update cursor position first
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };

    const consumed = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| blk: {
        log.err("mouse button callback error: {}", .{err});
        break :blk true;
    };

    // Unconsumed right-press under the default right-click-action =
    // context-menu: the core has already selected the hovered word/link
    // and returned false, signalling the apprt to show its context menu
    // (same contract the GTK apprt follows).
    if (!consumed and button == .right and action == .press) {
        showContextMenu(self, lparam);
    }
}

/// Show the surface right-click context menu at the given client coords
/// (packed in lparam like a mouse message). Items dispatch through the
/// core's binding actions, mirroring the macOS surface menu.
pub fn showContextMenu(self: *Surface, lparam: isize) void {
    const hwnd = self.hwnd orelse return;

    // The press handler took mouse capture; release it and clear the mask
    // before the modal menu loop, otherwise the pending button-up is
    // captured and immediately dismisses the menu.
    if (self.mouse_button_mask != 0) {
        self.mouse_button_mask = 0;
        _ = w32.ReleaseCapture();
    }

    // TrackPopupMenuEx's modal loop takes capture and swallows the physical
    // WM_RBUTTONUP, so the core would never see the right-button release and
    // would leave click_state[right] stuck at .press (corrupting later mouse
    // motion). Synthesize the release now.
    _ = self.core_surface.mouseButtonCallback(.release, .right, key_map.getModifiers()) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };

    const CTX_COPY: usize = 1;
    const CTX_PASTE: usize = 2;
    const CTX_SELECT_ALL: usize = 3;
    const CTX_SPLIT_RIGHT: usize = 4;
    const CTX_SPLIT_DOWN: usize = 5;
    const CTX_RESET: usize = 6;

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    const has_sel = self.core_surface.hasSelection();
    _ = w32.AppendMenuW(menu, if (has_sel) w32.MF_STRING else w32.MF_GRAYED, CTX_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SELECT_ALL, std.unicode.utf8ToUtf16LeStringLiteral("Select All"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SPLIT_DOWN, std.unicode.utf8ToUtf16LeStringLiteral("Split Down"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_RESET, std.unicode.utf8ToUtf16LeStringLiteral("Reset Terminal"));

    var pt = w32.POINT{
        .x = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        .y = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    };
    _ = w32.ClientToScreen(hwnd, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        hwnd,
        null,
    );

    const binding: ?input.Binding.Action = switch (@as(usize, @intCast(cmd))) {
        CTX_COPY => .{ .copy_to_clipboard = .mixed },
        CTX_PASTE => .paste_from_clipboard,
        CTX_SELECT_ALL => .select_all,
        CTX_SPLIT_RIGHT => .{ .new_split = .right },
        CTX_SPLIT_DOWN => .{ .new_split = .down },
        CTX_RESET => .reset,
        else => null,
    };
    if (binding) |b| {
        _ = self.core_surface.performBindingAction(b) catch |err| {
            log.err("context menu action failed err={}", .{err});
        };
    }
}

/// Handle WM_MOUSEMOVE.
pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    // Pass modifiers so the core can detect Ctrl+hover for link highlighting.
    const mods = key_map.getModifiers();

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

/// Handle WM_DROPFILES — a file (or files) was dropped onto this
/// surface. Convert each path to UTF-8, quote if it contains
/// whitespace, and paste into the terminal at the cursor.
pub fn handleDropFiles(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const hdrop: w32.HDROP = @ptrFromInt(wparam);
    defer w32.DragFinish(hdrop);

    const alloc = self.app.core_app.alloc;
    const text = (hdropPathsToUtf8(alloc, hdrop, self.paths) catch |err| {
        log.err("drop-files path conversion: {}", .{err});
        return;
    }) orelse return;
    defer alloc.free(text);

    // As a paste, as Windows Terminal drops files: programs that take
    // pasted paths as attachments (Claude Code turns an image's into
    // "[Image #1]") see one bracketed paste rather than typing.
    self.core_surface.textCallback(text) catch |err| {
        log.err("drop-files paste: {}", .{err});
    };
}

/// Convert the path list in an HDROP into one shell-ready UTF-8 string,
/// each path written and quoted as `style`'s shell reads it, joined with
/// single spaces.
///
/// Used by both WM_DROPFILES and CF_HDROP clipboard pastes. The caller owns
/// the returned slice; this function never releases the HDROP. A
/// WM_DROPFILES handle must be DragFinish'd by the caller. A clipboard
/// handle from GetClipboardData(CF_HDROP) must NOT be freed, DragFinish'd,
/// or unlocked — the clipboard owns it, and DragQueryFileW takes and drops
/// its own lock internally, so the caller neither locks nor unlocks it.
/// Returns null when there is nothing usable.
pub fn hdropPathsToUtf8(alloc: Allocator, hdrop: w32.HDROP, style: profiles.PathStyle) Allocator.Error!?[]u8 {
    // Number of files (passing 0xFFFFFFFF as iFile).
    const count = w32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // First call with NULL gets length (in chars, excluding NUL).
        const u16_len = w32.DragQueryFileW(hdrop, i, null, 0);
        if (u16_len == 0) continue;
        const u16_buf = try alloc.alloc(u16, u16_len + 1);
        defer alloc.free(u16_buf);
        const got = w32.DragQueryFileW(hdrop, i, u16_buf.ptr, @intCast(u16_buf.len));
        if (got == 0) continue;

        // UTF-16 → UTF-8.
        const utf8_buf = try alloc.alloc(u8, u16_buf.len * 4);
        defer alloc.free(utf8_buf);
        const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, u16_buf[0..got]) catch continue;
        const path = utf8_buf[0..utf8_len];

        // Separate from whatever we already appended rather than keying off
        // `i`, so a skipped entry can't leave a leading or doubled space.
        const before = buf.items.len;
        if (before > 0) try buf.append(alloc, ' ');
        if (!try appendShellPath(alloc, &buf, path, style)) buf.shrinkRetainingCapacity(before);
    }

    if (buf.items.len == 0) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}

/// Append `path` as `style`'s shell reads it, always quoted: Windows file
/// names may hold & | ( ) ; ^ < > and glob characters. False when the path
/// can't be written safely and is left out.
fn appendShellPath(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), path: []const u8, style: profiles.PathStyle) Allocator.Error!bool {
    switch (style) {
        .windows => {
            // A double quote can't occur in a path created through the
            // Win32 API, but volumes written by WSL, Samba/NFS, or via \\?\
            // paths can carry one. It would close the quotes and let the
            // rest be read as shell syntax, so such a path is refused.
            // Logged without the name: it can hold control characters.
            // Residual, and not fixable without knowing the shell: $(...)
            // and backticks still expand inside double quotes in
            // PowerShell, as does %VAR% in cmd.exe; pasting never submits
            // a line on its own.
            if (std.mem.indexOfScalar(u8, path, '"') != null) {
                log.warn("refusing to paste a path containing a double quote", .{});
                return false;
            }
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, path);
            try buf.append(alloc, '"');
        },
        // POSIX shells: single quotes expand nothing, and a quote inside
        // is written '\''.
        .wsl, .msys => {
            try buf.append(alloc, '\'');
            const rest = try appendPosixRoot(alloc, buf, path, style);
            for (rest) |c| switch (c) {
                '\\' => try buf.append(alloc, '/'),
                '\'' => try buf.appendSlice(alloc, "'\\''"),
                else => try buf.append(alloc, c),
            };
            try buf.append(alloc, '\'');
        },
    }
    return true;
}

/// Write where a Windows path lives in a WSL or MSYS shell's tree and
/// return the part of `path` after it: a drive "C:\" becomes /mnt/c or
/// /c, and a WSL distribution's own share (\\wsl.localhost\Ubuntu\...)
/// its root. Other network paths stay as they are.
fn appendPosixRoot(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), path: []const u8, style: profiles.PathStyle) Allocator.Error![]const u8 {
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
        try buf.appendSlice(alloc, if (style == .wsl) "/mnt/" else "/");
        try buf.append(alloc, std.ascii.toLower(path[0]));
        return path[2..];
    }
    if (style == .wsl) for ([_][]const u8{ "\\\\wsl.localhost\\", "\\\\wsl$\\" }) |share| {
        if (!std.ascii.startsWithIgnoreCase(path, share)) continue;
        const distro_end = std.mem.indexOfScalarPos(u8, path, share.len, '\\') orelse return "/";
        return path[distro_end..];
    };
    return path;
}

/// Handle WM_MOUSEWHEEL (vertical) and WM_MOUSEHWHEEL (horizontal).
/// `axis` selects which scroll axis to deliver the delta on.
pub fn handleMouseWheel(self: *Surface, wparam: usize, axis: enum { vertical, horizontal }) void {
    if (!self.core_surface_ready) return;
    // The high word of wparam contains the wheel delta (signed).
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));

    const scroll_mods: input.ScrollMods = .{};

    // Win32 horizontal wheel positive-right; core API positive-right also.
    const xoff: f64 = if (axis == .horizontal) delta else 0;
    const yoff: f64 = if (axis == .vertical) delta else 0;
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

/// Set the mouse cursor shape. Caches the handle so WM_SETCURSOR can
/// restore it (Windows resets the cursor on every mouse move otherwise).
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}

/// Handle WM_SETCURSOR — restore our cached cursor so Windows doesn't
/// reset it to the class cursor (IDC_ARROW) on every mouse move.
/// Returns true if we handled it (caller should return TRUE).
pub fn handleSetCursor(self: *Surface) bool {
    // Hidden cursor: pass NULL.
    if (!self.mouse_visible) {
        _ = w32.SetCursor(null);
        return true;
    }
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}

/// Show (or clear, when url is empty) the hovered-URL preview at the
/// bottom-left of the surface, like a browser status bubble. Driven by the
/// mouse_over_link action.
pub fn setMouseOverLink(self: *Surface, url: []const u8) void {
    if (url.len == 0) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        return;
    }
    const hwnd = self.hwnd orelse return;
    const s = self.scale;

    if (self.link_preview_hwnd == null) {
        self.link_preview_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            self.parent_window.hwnd.?,
            null,
            self.app.hinstance,
            null,
        );
        if (self.link_preview_hwnd) |h| {
            if (self.link_font == null) {
                self.link_font = w32.CreateFontW(
                    -@as(i32, @intFromFloat(@round(13.0 * s))),
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
            if (self.link_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const preview = self.link_preview_hwnd orelse return;

    var buf16: [512]u16 = undefined;
    const truncated = if (url.len > 480) url[0..480] else url;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, truncated) catch return;
    buf16[@min(len16, buf16.len - 1)] = 0;
    _ = w32.SetWindowTextW(preview, @ptrCast(&buf16));

    // Rough width from character count, capped to the surface width.
    const char_w: i32 = @intFromFloat(@round(7.0 * s));
    const pad: i32 = @intFromFloat(@round(12.0 * s));
    const pw: i32 = @min(
        @as(i32, @intCast(self.width)),
        @as(i32, @intCast(len16)) * char_w + pad,
    );
    const ph: i32 = @intFromFloat(@round(22.0 * s));
    var pt = w32.POINT{ .x = 0, .y = @as(i32, @intCast(self.height)) - ph };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(preview, null, pt.x, pt.y, pw, ph, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(preview, w32.SW_SHOWNOACTIVATE);
}
