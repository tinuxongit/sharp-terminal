const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const menu_theme = @import("menu_theme.zig");
const profiles = @import("profiles.zig");
const servers = @import("servers.zig");
const server_shell = @import("server_shell.zig");
const server_folder_picker = @import("server_folder_picker.zig");
const server_sign_in = @import("server_sign_in.zig");
const remote_desktop = @import("remote_desktop.zig");
const strip_mouse = @import("strip_mouse.zig");
const workspace = @import("workspace.zig");
const Window = @import("Window.zig");

const text = profiles.data.sidebar.server_menu;

pub const Command = enum(usize) {
    new_tab = 1,
    open_folder,
    sign_in,
    remote_desktop,
    remove,
};

pub fn appendTo(menu: w32.HMENU, with_remove: bool) void {
    append(menu, .new_tab, text.new_tab);
    append(menu, .open_folder, text.open_folder);
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    append(menu, .remote_desktop, text.remote_desktop);
    append(menu, .sign_in, text.sign_in);
    if (!with_remove) return;
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    append(menu, .remove, text.remove);
}

pub fn show(self: *Window, first_tab: usize, point: w32.POINT, with_remove: bool) ?Command {
    const hwnd = self.hwnd orelse return null;
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    appendTo(menu, with_remove);
    menu_theme.apply(strip_mouse.menusDark(self));
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, hwnd, null);
    const command = std.enums.fromInt(Command, @as(usize, @intCast(@max(0, picked)))) orelse return null;
    if (command != .remove) run(self, first_tab, command, point);
    return command;
}

fn run(self: *Window, first_tab: usize, command: Command, point: w32.POINT) void {
    var host_buf: [servers.max_len]u8 = undefined;
    const host = copy(&host_buf, workspace.groupKey(self, first_tab));
    switch (command) {
        .new_tab => _ = workspace.openServer(self, host, self.tab_active_surface[first_tab].serverFolder()),
        .open_folder => openFolder(self, host, self.tab_active_surface[first_tab].serverFolder(), point),
        .sign_in => server_sign_in.start(self, host),
        .remote_desktop => switch (remote_desktop.open(self.app.core_app.alloc, host)) {
            .launched, .unknown_host => {},
            .no_desktop => if (ask(self, text.no_desktop_title, text.no_desktop_text)) {
                _ = workspace.openServerAfter(self, host, null, text.install_desktop);
            },
        },
        .remove => {},
    }
}

pub fn openFolder(self: *Window, host: []const u8, start: []const u8, point: w32.POINT) void {
    const hwnd = self.hwnd orelse return;
    var folder_buf: [server_shell.max_folder_len]u8 = undefined;
    switch (server_folder_picker.pick(self.app.core_app.alloc, hwnd, point, host, start, &folder_buf, strip_mouse.menusDark(self))) {
        .cancelled => {},
        .folder => |folder| _ = workspace.openServer(self, host, folder),
        .unreachable_without_password => if (ask(self, text.password_needed_title, text.password_needed_text)) server_sign_in.start(self, host),
    }
}

fn copy(buf: []u8, value: []const u8) []const u8 {
    const n = @min(buf.len, value.len);
    @memcpy(buf[0..n], value[0..n]);
    return buf[0..n];
}

fn append(menu: w32.HMENU, command: Command, label: []const u8) void {
    var wide: [96]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, label);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, @intFromEnum(command), @ptrCast(&wide));
}

fn ask(self: *Window, title: []const u8, body: []const u8) bool {
    var title_wide: [128:0]u16 = undefined;
    title_wide[wide_string.fromUtf8(&title_wide, title)] = 0;
    var body_wide: [512:0]u16 = undefined;
    body_wide[wide_string.fromUtf8(&body_wide, body)] = 0;
    return w32.MessageBoxW(self.hwnd, &body_wide, &title_wide, w32.MB_YESNO | w32.MB_ICONQUESTION) == w32.IDYES;
}
