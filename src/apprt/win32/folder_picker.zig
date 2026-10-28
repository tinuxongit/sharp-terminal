//! Windows' own folder picker (IFileOpenDialog with FOS_PICKFOLDERS), for
//! opening a tab in a folder chosen from the sidebar.
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");

/// Ask for a folder, starting in `start`. Returns its path in `out`, or
/// null when the user cancels or the dialog can't be shown.
pub fn pick(owner: w32.HWND, title: []const u8, start: []const u8, out: []u8) ?[]const u8 {
    // The UI thread may not have initialized COM yet; doing it twice is fine.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

    var raw: ?*anyopaque = null;
    if (w32.CoCreateInstance(&w32.CLSID_FileOpenDialog, null, w32.CLSCTX_INPROC_SERVER, &w32.IID_IFileOpenDialog, &raw) < 0) return null;
    const dialog: *w32.IFileOpenDialog = @ptrCast(@alignCast(raw orelse return null));
    defer _ = dialog.vtable.Release(dialog);

    var options: u32 = 0;
    _ = dialog.vtable.GetOptions(dialog, &options);
    _ = dialog.vtable.SetOptions(dialog, options | w32.FOS_PICKFOLDERS | w32.FOS_FORCEFILESYSTEM);
    var wide_title: [128]u16 = undefined;
    _ = wide_string.fromUtf8(&wide_title, title);
    _ = dialog.vtable.SetTitle(dialog, @ptrCast(&wide_title));

    if (start.len > 0) {
        var wide_start: [260]u16 = undefined;
        _ = wide_string.fromUtf8(&wide_start, start);
        var folder_raw: ?*anyopaque = null;
        if (w32.SHCreateItemFromParsingName(@ptrCast(&wide_start), null, &w32.IID_IShellItem, &folder_raw) >= 0) {
            if (folder_raw) |r| {
                const folder: *w32.IShellItem = @ptrCast(@alignCast(r));
                defer _ = folder.vtable.Release(folder);
                _ = dialog.vtable.SetFolder(dialog, folder);
            }
        }
    }

    // Show fails with ERROR_CANCELLED when the user closes the dialog.
    if (dialog.vtable.Show(dialog, owner) < 0) return null;
    var result: ?*w32.IShellItem = null;
    if (dialog.vtable.GetResult(dialog, &result) < 0) return null;
    const item = result orelse return null;
    defer _ = item.vtable.Release(item);

    var path: ?[*:0]u16 = null;
    if (item.vtable.GetDisplayName(item, w32.SIGDN_FILESYSPATH, &path) < 0) return null;
    defer w32.CoTaskMemFree(path);
    const len = wide_string.toUtf8(out, std.mem.span(path orelse return null));
    return out[0..len];
}
