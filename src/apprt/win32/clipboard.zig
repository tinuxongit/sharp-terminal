//! The Windows clipboard for a terminal pane: reading it for paste (text,
//! or the paths of copied files) with the core's confirmation when a
//! paste or a program's read needs one, and writing what the core copies.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const log = std.log.scoped(.win32);
const Surface = @import("Surface.zig");
const pane_mouse = @import("pane_mouse.zig");

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

/// Normalize the newline convention required by CF_UNICODETEXT before the
/// shared paste encoder sees it. Windows clipboard producers conventionally
/// use CRLF, while the non-bracketed encoder turns LF into CR. Passing CRLF
/// through unchanged would therefore produce CRCR and submit an extra blank
/// line for every pasted line. Preserve lone CR and LF bytes as supplied.
pub fn normalizeWindowsClipboardNewlines(data: []u8) []u8 {
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < data.len) {
        if (data[read_idx] == '\r' and
            read_idx + 1 < data.len and
            data[read_idx + 1] == '\n')
        {
            data[write_idx] = '\n';
            read_idx += 2;
        } else {
            data[write_idx] = data[read_idx];
            read_idx += 1;
        }
        write_idx += 1;
    }

    return data[0..write_idx];
}

test "normalize Windows clipboard newlines" {
    var data = "one\r\ntwo\r\n\r\nthree\rfour\n".*;
    const normalized = normalizeWindowsClipboardNewlines(data[0..]);
    try std.testing.expectEqualStrings("one\ntwo\n\nthree\rfour\n", normalized);
}

/// Show a modal clipboard confirmation dialog on the owning window and
/// return true if the user approved. Mirrors the macOS/GTK clipboard
/// confirmation flow so the core's paste-protection and OSC 52
/// authorization guards actually gate the operation on Windows.
pub fn confirmClipboard(
    self: *Surface,
    comptime message: [:0]const u8,
    comptime title: [:0]const u8,
) bool {
    const result = w32.MessageBoxW(
        self.parent_window.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(message),
        std.unicode.utf8ToUtf16LeStringLiteral(title),
        // Default to Cancel so an accidental Enter does not approve.
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return .unsupported;

    // Kitty writes carry their committed representations in the request, so
    // they only need to pass through the core's authorization flow.
    if (state == .kitty_write) {
        return completeClipboardRequestWithConfirmation(
            self,
            state,
            &.{},
            &.{},
        );
    }

    // Paste events request a target listing without reading clipboard data.
    // Win32 exposes files and Unicode text as a text/plain representation.
    if (state == .list) {
        if (w32.OpenClipboard(self.hwnd) == 0) {
            log.warn("OpenClipboard failed", .{});
            return .unavailable;
        }
        defer _ = w32.CloseClipboard();

        if (w32.GetClipboardData(w32.CF_HDROP) == null and
            w32.GetClipboardData(w32.CF_UNICODETEXT) == null)
        {
            return .unavailable;
        }

        return completeClipboardRequestWithConfirmation(
            self,
            state,
            &.{},
            &.{"text/plain"},
        );
    }

    const alloc = self.app.core_app.alloc;

    // Read the clipboard into an owned UTF-8 string in a tight scope so the
    // system clipboard is CLOSED before any modal confirmation dialog — the
    // dialog can be up for an unbounded time and would otherwise block every
    // other process's clipboard access.
    const utf8z: [:0]const u8 = blk: {
        if (w32.OpenClipboard(self.hwnd) == 0) {
            log.warn("OpenClipboard failed", .{});
            return .unavailable;
        }
        defer _ = w32.CloseClipboard();

        // Files copied in Explorer land on the clipboard as CF_HDROP with no
        // text format at all, so a plain CF_UNICODETEXT read pastes nothing.
        // Paste them as space-separated, quoted paths — the same rendering
        // WM_DROPFILES already produces, and the parity match for macOS,
        // which pastes shell-escaped paths for file pasteboards.
        //
        // CF_HDROP wins when a source offers both formats: its text is
        // normally the same paths unquoted, and the quoted form is the one
        // that actually works when the paste lands on a shell command line.
        if (w32.GetClipboardData(w32.CF_HDROP)) |hdrop_handle| hdrop: {
            // Pass the handle straight to DragQueryFileW, which locks it
            // internally — exactly as handleDropFiles does with the HDROP
            // from WM_DROPFILES. Do NOT GlobalLock and pass the resulting
            // pointer: clipboard data is moveable, so the handle and the
            // locked address are different values. And never DragFinish it;
            // the clipboard owns this handle, not us.
            const paths = (try pane_mouse.hdropPathsToUtf8(alloc, @ptrCast(hdrop_handle))) orelse
                break :hdrop;
            defer alloc.free(paths);
            break :blk try alloc.dupeSentinel(u8, paths, 0);
        }

        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse
            return .unavailable;
        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return .unavailable;
        };
        defer _ = w32.GlobalUnlock(hglobal);

        // Any program can put text there without a terminator, so the
        // block's size bounds the search for one.
        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));
        const capacity = w32.GlobalSize(hglobal) / 2;
        const wlen = std.mem.indexOfScalar(u16, wptr[0..capacity], 0) orelse capacity;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return .unavailable;
        };
        defer alloc.free(utf8);
        break :blk try alloc.dupeSentinel(
            u8,
            normalizeWindowsClipboardNewlines(utf8),
            0,
        );
    };
    defer alloc.free(utf8z);

    return completeClipboardRequestWithConfirmation(
        self,
        state,
        &.{.{ .mime = "text/plain", .data = utf8z }},
        &.{},
    );
}

/// Complete a structured clipboard request and run the native authorization
/// prompt when the core requires it. The modal dialog can destroy the surface,
/// so all post-dialog access re-resolves the core surface by id.
pub fn completeClipboardRequestWithConfirmation(
    self: *Surface,
    state: apprt.ClipboardRequest,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) apprt.ClipboardReadResult {
    const core_app = self.app.core_app;
    const surface_id = self.core_surface.id;

    // Complete with confirmed=false so the core runs its safety checks. If it
    // flags the paste as unsafe (paste-protection) or the OSC 52 read as
    // unauthorized (clipboard-read = ask), prompt and only re-complete with
    // confirmed=true on approval. Passing confirmed=true up front — as this
    // used to — silently disabled both guards on Windows.
    self.core_surface.completeClipboardRequest(state, .{
        .contents = contents,
        .available = available,
    }) catch |err| {
        // confirmClipboard takes comptime strings (utf8ToUtf16LeStringLiteral),
        // so each error path calls it with its own literals. `self` may be
        // freed while the modal dialog pumps messages, so re-resolve the
        // surface by id before re-completing.
        const approved = switch (err) {
            error.UnsafePaste => confirmClipboard(
                self,
                "The text being pasted contains characters that could run " ++
                    "commands unexpectedly (for example, newlines).\n\nPaste anyway?",
                brand.name ++ " \u{2014} Potentially Unsafe Paste",
            ),
            error.UnauthorizedPaste => switch (state) {
                .kitty_write, .osc_52_write => confirmClipboard(
                    self,
                    "An application is requesting to write to the system clipboard.\n\nAllow this?",
                    brand.name ++ " \u{2014} Authorize Clipboard Access",
                ),
                else => confirmClipboard(
                    self,
                    "An application is requesting access to read the clipboard.\n\nAllow this?",
                    brand.name ++ " \u{2014} Authorize Clipboard Access",
                ),
            },
            else => {
                log.err("completeClipboardRequest error: {}", .{err});
                return .started;
            },
        };

        const cs = core_app.findSurfaceByID(surface_id) orelse {
            // Kitty requests own arenas that the apprt must release even if
            // their surface disappeared while the modal dialog was open.
            switch (state) {
                .kitty_read => |kitty| kitty.destroy(),
                .kitty_write => |kitty| kitty.destroy(),
                else => {},
            }
            return .started;
        };

        if (approved) {
            cs.completeClipboardRequest(state, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            }) catch |e| {
                log.err("completeClipboardRequest (confirmed) error: {}", .{e});
            };
        } else {
            cs.denyClipboardRequest(state);
        }
    };

    return .started;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return;

    // The confirm dialog below pumps messages and can free `self` (child
    // exit → surface close). Capture the App (stable for the process) and
    // avoid dereferencing `self` after the prompt.
    const app = self.app;

    // When the core requests confirmation (e.g. an OSC 52 clipboard write
    // with clipboard-write = ask), prompt before writing. Previously the
    // flag was discarded, so remote apps could write the clipboard silently.
    if (confirm) {
        if (!confirmClipboard(
            self,
            "An application is requesting to write to the system clipboard.\n\nAllow this?",
            brand.name ++ " \u{2014} Authorize Clipboard Access",
        )) return;
    }

    // Find the text/plain content.
    const text = blk: {
        for (contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break :blk c.data;
        }
        // No text/plain content; nothing to write.
        return;
    };

    const alloc = app.core_app.alloc;

    // Convert UTF-8 to UTF-16LE.  Add 1 for the null terminator.
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);

    // Size in bytes including the null terminator (u16 → 2 bytes each).
    const byte_size = (utf16.len + 1) * @sizeOf(u16);

    // Allocate a moveable global memory block.
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return;
    };

    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    };

    // Copy the UTF-16LE data (including null terminator) into the block.
    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0; // null terminator

    _ = w32.GlobalUnlock(hglobal);

    // null owner: the write is not tied to the (possibly freed) surface hwnd.
    if (w32.OpenClipboard(null) == 0) {
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();

    _ = w32.EmptyClipboard();

    // SetClipboardData takes ownership of hglobal on success.
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(hglobal);
    }
}
