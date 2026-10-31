const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const menu_theme = @import("menu_theme.zig");
const profiles = @import("profiles.zig");
const shell_open = @import("shell_open.zig");
const strip_mouse = @import("strip_mouse.zig");
const tab_sidebar = @import("tab_sidebar.zig");
const workspace = @import("workspace.zig");
const server_menu = @import("server_menu.zig");
const Window = @import("Window.zig");

const text = profiles.data.sidebar.group_menu;

const Command = enum(usize) {
    new_tab = 1,
    open_folder,
    remove,
};

pub fn show(self: *Window, first_tab: usize, x: i32, y: i32) void {
    const hwnd = self.hwnd orelse return;
    var point: w32.POINT = .{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &point);
    const section = workspace.tabSection(self, first_tab);
    if (section == .servers) {
        if (server_menu.show(self, first_tab, point, true) == .remove) closeGroup(self, first_tab);
        return;
    }

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    append(menu, .new_tab, text.new_tab);
    append(menu, .open_folder, text.open_folder);
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    append(menu, .remove, text.remove_folder);

    menu_theme.apply(strip_mouse.menusDark(self));
    const picked = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, hwnd, null);
    const command = std.enums.fromInt(Command, @as(usize, @intCast(@max(0, picked)))) orelse return;

    const folder = self.tab_active_surface[first_tab].folderPath();
    switch (command) {
        .new_tab => workspace.openInSection(self, section, null, folder),
        .open_folder => shell_open.folder(folder),
        .remove => closeGroup(self, first_tab),
    }
}

fn append(menu: w32.HMENU, command: Command, label: []const u8) void {
    var wide: [64]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, label);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, @intFromEnum(command), @ptrCast(&wide));
}

fn closeGroup(self: *Window, first_tab: usize) void {
    const section = workspace.tabSection(self, first_tab);
    const key = workspace.groupKey(self, first_tab);
    var ids: [Window.MAX_TABS]u64 = undefined;
    var count: usize = 0;
    for (0..self.tab_count) |i| {
        if (workspace.tabSection(self, i) != section or !tab_sidebar.sameGroup(workspace.groupKey(self, i), key)) continue;
        ids[count] = self.tabId(i);
        count += 1;
    }
    self.requestCloseTabs(ids[0..count]);
}
