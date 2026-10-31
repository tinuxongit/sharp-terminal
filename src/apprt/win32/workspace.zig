//! Workspace mode's side of a Window: grouping tabs by section and folder,
//! the sidebar's input (clicks, keys, its search and server boxes, menus),
//! opening tabs in folders or on servers from it, and the polling that
//! files SSH sessions under Servers. tab_sidebar.zig lays it out and paints.
const std = @import("std");
const browser_dock = @import("browser_dock.zig");
const elevation = @import("elevation.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const tab_strip = @import("tab_strip.zig");
const profiles = @import("profiles.zig");
const new_tab_menu = @import("new_tab_menu.zig");
const tab_sidebar = @import("tab_sidebar.zig");
const tab_status = @import("tab_status.zig");
const folder_picker = @import("folder_picker.zig");
const canvas_mod = @import("canvas.zig");
const SearchField = @import("SearchField.zig");
const ssh = @import("ssh.zig");
const process_tree = @import("process_tree.zig");
const termio = @import("../../termio.zig");
const claude_session = @import("claude_session.zig");
const session = @import("session.zig");
const servers = @import("servers.zig");
const server_shell = @import("server_shell.zig");
const server_menu = @import("server_menu.zig");
const nearby_servers = @import("nearby_servers.zig");
const server_tunnel = @import("server_tunnel.zig");
const configpkg = @import("../../config.zig");
const log = std.log.scoped(.win32);
const Window = @import("Window.zig");
const strip_mouse = @import("strip_mouse.zig");
const ai_usage = @import("ai_usage.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");

pub fn paintSidebar(self: *Window, hdc_screen: w32.HDC, palette: tab_strip.Palette) void {
    const rect = sidebarRect(self);
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return;

    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(mem_dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    const old = w32.SelectObject(mem_dc, bitmap);
    defer {
        _ = w32.SelectObject(mem_dc, old);
        _ = w32.DeleteObject(bitmap);
    }

    var titles: [Window.MAX_TABS][256]u8 = undefined;
    var labels: [Window.MAX_TABS][256]u8 = undefined;
    var items: [Window.MAX_TABS]tab_sidebar.Item = undefined;
    const now = w32.GetTickCount64();
    for (0..self.tab_count) |i| {
        const surface = self.tab_active_surface[i];
        const title_len = wide_string.toUtf8(&titles[i], self.tab_titles[i][0..self.tab_title_lens[i]]);
        items[i] = .{
            .tab = i,
            .title = titles[i][0..title_len],
            .icon = self.tabIcon(i),
            .section = tabSection(self, i),
            .group = groupKey(self, i),
            .group_label = groupLabel(self, i, &labels[i]),
            .age_ms = now -| surface.opened_ms,
            .attention = tabNeedsAttention(self, i),
            .status = tab_status.ofTab(&self.tab_trees[i]),
        };
    }
    var collapsed: [Window.max_collapsed][]const u8 = undefined;
    var hint_buf: [servers.max_len + 64]u8 = undefined;
    const server_hint = if (self.server_field_address.len > 0)
        std.fmt.bufPrint(&hint_buf, profiles.data.sidebar.server_menu.user_for, .{self.server_field_address.text()}) catch profiles.data.sidebar.server_placeholder
    else
        profiles.data.sidebar.server_placeholder;

    const canvas: canvas_mod.Canvas = .{ .hdc = mem_dc, .pixels = @ptrCast(@alignCast(bits orelse return)), .width = width, .height = height };
    self.sidebar_max_scroll = tab_sidebar.paint(canvas, self.scale, palette, self.sidebar_fonts, .{
        .items = items[0..self.tab_count],
        .active = self.active_tab,
        .hover = self.sidebar_hover,
        .search = &self.sidebar_search,
        .window_focused = self.window_active,
        .scroll = self.sidebar_scroll,
        .collapsed = collapsedGroups(self, &collapsed),
        .dragging = if (self.sidebar_dragging) self.sidebar_drag else null,
        .pressed = self.sidebar_pressed,
        .has_wsl = self.has_wsl,
        .server_field = if (self.server_field.focused) &self.server_field else null,
        .server_field_hint = server_hint,
        .usage = usage: {
            const config = &self.app.config;
            ai_usage.setEnabled(.{
                .claude = config.@"ai-usage-claude",
                .claude_session = config.@"ai-usage-claude-session",
                .claude_weekly = config.@"ai-usage-claude-weekly",
                .claude_models = config.@"ai-usage-claude-models",
                .codex = config.@"ai-usage-codex",
                .codex_session = config.@"ai-usage-codex-session",
                .codex_weekly = config.@"ai-usage-codex-weekly",
                .codex_models = config.@"ai-usage-codex-models",
                .opencode = config.@"ai-usage-opencode",
            });
            break :usage ai_usage.snapshot();
        },
        .usage_folded = isCollapsed(self, usage_fold_key),
        .now_s = std.Io.Clock.now(.real, global.io()).toSeconds(),
    }, &self.sidebar_spots);
    // Usage is read only once a sidebar is shown, so Tabs mode never runs
    // the CLIs.
    if (self.app.msg_hwnd) |hwnd| ai_usage.ensureStarted(hwnd, App.WM_APP_AI_USAGE);
    canvas.sync();
    _ = w32.BitBlt(hdc_screen, rect.left, rect.top, width, height, mem_dc, 0, 0, w32.SRCCOPY);
}

pub fn tabNeedsAttention(self: *Window, index: usize) bool {
    var it = self.tab_trees[index].iterator();
    while (it.next()) |entry| {
        if (entry.view.attention) return true;
    }
    return false;
}

/// A bell from a tab the user can't see marks it in the sidebar until
/// it is selected.
pub fn noteBell(self: *Window, surface: *Surface) void {
    if (self.paneInSight(surface)) return;
    surface.attention = true;
    self.invalidateTabBar();
}

pub fn sidebarTarget(self: *Window, x: i32, y: i32) tab_sidebar.Target {
    if (!inSidebar(self, x, y)) return .none;
    const r = sidebarRect(self);
    const spot = self.sidebar_spots.at(x - r.left, y - r.top) orelse return .none;
    return spot.target;
}

pub fn setSidebarHover(self: *Window, target: tab_sidebar.Target) void {
    if (target.eql(self.sidebar_hover)) return;
    self.sidebar_hover = target;
    self.invalidateTabBar();
}

/// The sidebar's text box that has the keyboard, if any.
pub fn sidebarField(self: *Window) ?*SearchField {
    if (self.sidebar_search.focused) return &self.sidebar_search;
    if (self.server_field.focused) return &self.server_field;
    return null;
}

pub fn focusSidebarSearch(self: *Window, focused: bool) void {
    focusSidebarField(self, &self.sidebar_search, focused);
}

/// Open or close the server address box; it shows only while focused.
pub fn focusServerField(self: *Window, focused: bool) void {
    if (!focused) {
        self.server_field.clear();
        self.server_field_address = .{};
    }
    focusSidebarField(self, &self.server_field, focused);
}

pub fn focusSidebarField(self: *Window, field: *SearchField, focused: bool) void {
    const hwnd = self.hwnd orelse return;
    if (field.focused == focused) return;
    field.focus(hwnd, focused);
    if (focused) {
        _ = w32.SetFocus(hwnd);
    } else if (self.getActiveSurface()) |surface| {
        if (surface.hwnd) |h| _ = w32.SetFocus(h);
    }
    self.invalidateTabBar();
}

pub fn sidebarClick(self: *Window, x: i32, y: i32) void {
    const target = sidebarTarget(self, x, y);
    if (target != .search) focusSidebarSearch(self, false);
    if (target != .server_field) focusServerField(self, false);
    const hwnd = self.hwnd orelse return;
    switch (target) {
        .none => {},
        .search => focusSidebarSearch(self, true),
        .resize => {
            self.sidebar_resizing = true;
            _ = w32.SetCapture(hwnd);
        },
        .tab => |i| {
            self.selectTabIndex(i);
            // A press may become a drag to reorder; see WM_MOUSEMOVE.
            self.sidebar_drag = i;
            self.sidebar_drag_y = y;
            self.sidebar_dragging = false;
            _ = w32.SetCapture(hwnd);
        },
        .close => |i| self.requestCloseTabs(&.{self.tabId(i)}),
        .group => |i| {
            var buf: [300]u8 = undefined;
            toggleCollapsed(self, tab_sidebar.collapseKey(&buf, tabSection(self, i), groupKey(self, i)));
        },
        .group_new => |i| switch (tabSection(self, i)) {
            .servers => _ = openServer(self, groupKey(self, i), self.tab_active_surface[i].serverFolder()),
            else => |section| openInSection(self, section, null, self.tab_active_surface[i].folderPath()),
        },
        .group_menu => |i| if (tabSection(self, i) == .servers) {
            const corner = pressSidebarArrow(self, target) orelse return;
            defer releaseSidebarArrow(self);
            _ = server_menu.show(self, i, corner, false);
        } else {
            const list = profiles.detect();
            const index = sidebarProfileMenu(self, target, &list) orelse return;
            self.openPicked(&list, index, self.tab_active_surface[i].folderPath(), false);
        },
        .section, .server_field => {},
        .usage_title => toggleCollapsed(self, usage_fold_key),
        .section_new => |section| switch (section) {
            .servers => focusServerField(self, true),
            else => pickFolderAndOpen(self, section, null),
        },
        .section_menu => |section| switch (section) {
            .servers => {
                const picked = sidebarServerMenu(self, target) orelse return;
                if (picked.nearby) return askUserFor(self, picked.name.text());
                _ = openServer(self, picked.name.text(), null);
            },
            else => {
                const list = profiles.detect();
                const index = sidebarProfileMenu(self, target, &list) orelse return;
                // Ctrl is read now: the folder picker comes in between.
                if (elevation.requested()) {
                    var buf: [1024]u8 = undefined;
                    const folder = pickFolder(self, &buf) orelse return;
                    return elevation.open(list.command(index), folder);
                }
                pickFolderAndOpen(self, section, index);
            },
        },
    }
}

pub fn scrollSidebar(self: *Window, delta: i32) void {
    const next = std.math.clamp(self.sidebar_scroll + delta, 0, self.sidebar_max_scroll);
    if (next == self.sidebar_scroll) return;
    self.sidebar_scroll = next;
    self.invalidateTabBar();
}

/// Keys typed while the sidebar's search box has focus. Escape clears it
/// and gives the terminal back the keyboard; Enter opens the first match.
pub fn sidebarKey(self: *Window, vk: u16) void {
    const hwnd = self.hwnd orelse return;
    switch (vk) {
        w32.VK_ESCAPE => {
            self.sidebar_search.clear();
            focusSidebarSearch(self, false);
        },
        w32.VK_RETURN => {
            const first = for (0..self.sidebar_spots.len) |i| {
                switch (self.sidebar_spots.items[i].target) {
                    .tab => |tab| break tab,
                    else => {},
                }
            } else null;
            focusSidebarSearch(self, false);
            if (first) |tab| self.selectTabIndex(tab);
        },
        else => if (self.sidebar_search.key(hwnd, vk)) {
            self.sidebar_scroll = 0;
            self.invalidateTabBar();
        },
    }
}

/// Keys typed in the server address box. Enter connects; Escape closes it.
pub fn serverFieldKey(self: *Window, vk: u16) void {
    const hwnd = self.hwnd orelse return;
    switch (vk) {
        w32.VK_ESCAPE => focusServerField(self, false),
        w32.VK_RETURN => {
            const trimmed = std.mem.trim(u8, self.server_field.text(), " ");
            var joined_buf: [servers.max_len]u8 = undefined;
            const address = self.server_field_address.text();
            const destination = if (address.len > 0 and trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '@') == null)
                std.fmt.bufPrint(&joined_buf, "{s}@{s}", .{ trimmed, address }) catch trimmed
            else if (trimmed.len == 0) address else trimmed;
            const typed = servers.Name.init(destination);
            focusServerField(self, false);
            if (typed.len > 0) _ = openServer(self, typed.text(), null);
        },
        else => if (self.server_field.key(hwnd, vk)) self.invalidateTabBar(),
    }
}

pub fn tabSection(self: *Window, tab: usize) tab_sidebar.Section {
    const surface = self.tab_active_surface[tab];
    return if (surface.sshHost().len > 0) .servers else if (surface.wsl) .wsl else .local;
}

/// What a tab is grouped by in the sidebar: its SSH server, else its folder.
pub fn groupKey(self: *Window, tab: usize) []const u8 {
    const surface = self.tab_active_surface[tab];
    const host = surface.sshHost();
    return if (host.len > 0) host else surface.folderPath();
}

/// The group's label: the folder's name, with its parent added when two
/// open folders share a name.
pub fn groupLabel(self: *Window, tab: usize, buf: []u8) []const u8 {
    const surface = self.tab_active_surface[tab];
    const host = surface.sshHost();
    if (host.len > 0) return host;
    const name = surface.folderName();
    const clash = for (0..self.tab_count) |j| {
        const other = self.tab_active_surface[j];
        if (other.sshHost().len == 0 and std.ascii.eqlIgnoreCase(other.folderName(), name) and
            !tab_sidebar.sameGroup(other.folderPath(), surface.folderPath())) break true;
    } else false;
    if (!clash) return name;
    const path = surface.folderPath();
    const name_start = path.len - name.len;
    const parent_end = if (name_start > 0) name_start - 1 else 0;
    const parent_start = if (std.mem.lastIndexOfScalar(u8, path[0..parent_end], '\\')) |i| i + 1 else 0;
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ path[parent_start..parent_end], name }) catch name;
}

pub fn collapsedGroups(self: *const Window, buf: *[Window.max_collapsed][]const u8) []const []const u8 {
    for (0..self.collapsed_count) |i| buf[i] = self.collapsed[i][0..self.collapsed_lens[i]];
    return buf[0..self.collapsed_count];
}

/// The AI section folds like a group, remembered in the same list (and so
/// in the session); no folder key looks like it.
const usage_fold_key = "ai";

fn isCollapsed(self: *const Window, key: []const u8) bool {
    for (0..self.collapsed_count) |i| {
        if (tab_sidebar.sameGroup(self.collapsed[i][0..self.collapsed_lens[i]], key)) return true;
    }
    return false;
}

pub fn toggleCollapsed(self: *Window, key: []const u8) void {
    for (0..self.collapsed_count) |i| {
        if (!tab_sidebar.sameGroup(self.collapsed[i][0..self.collapsed_lens[i]], key)) continue;
        self.collapsed_count -= 1;
        self.collapsed[i] = self.collapsed[self.collapsed_count];
        self.collapsed_lens[i] = self.collapsed_lens[self.collapsed_count];
        self.invalidateTabBar();
        self.app.saveSession();
        return;
    }
    if (self.collapsed_count == Window.max_collapsed or key.len > self.collapsed[0].len) return;
    @memcpy(self.collapsed[self.collapsed_count][0..key.len], key);
    self.collapsed_lens[self.collapsed_count] = @intCast(key.len);
    self.collapsed_count += 1;
    self.invalidateTabBar();
    self.app.saveSession();
}

/// Apply a saved sidebar width and folded groups.
pub fn restoreSidebar(self: *Window, width: f32, collapsed: []const []const u8) void {
    self.sidebar_width = std.math.clamp(width, tab_sidebar.min_width, tab_sidebar.max_width);
    self.collapsed_count = 0;
    for (collapsed) |key| {
        if (self.collapsed_count == Window.max_collapsed or key.len > self.collapsed[0].len) continue;
        @memcpy(self.collapsed[self.collapsed_count][0..key.len], key);
        self.collapsed_lens[self.collapsed_count] = @intCast(key.len);
        self.collapsed_count += 1;
    }
    self.handleResize();
}

/// This window's tabs as the session saves them.
pub fn sessionWindow(self: *Window, buf: *[64]session.Tab, arena: std.mem.Allocator) session.Window {
    const n = @min(self.tab_count, buf.len);
    for (0..n) |i| buf[i] = sessionTab(self.tab_active_surface[i], arena);
    return .{ .tabs = buf[0..n], .active = self.active_tab };
}

/// What reopens a tab: its shell, folder, server and conversation. The
/// text belongs to `surface`.
pub fn sessionTab(surface: *const Surface, arena: ?std.mem.Allocator) session.Tab {
    const claude: ?*const claude_session.Session = if (surface.claude) |*c| c else null;
    return .{
        .profile = surface.profileName(),
        // A conversation resumes only from the folder Claude Code ran in.
        .folder = if (surface.sshHost().len > 0) surface.serverFolder() else if (claude != null and claude.?.folder().len > 0) claude.?.folder() else surface.folderPath(),
        .server = surface.sshHost(),
        .claude = if (claude) |c| &c.id else "",
        .pages = if (arena) |a| browser_dock.pagesOf(surface.parent_window, surface.pane_id, a) else &.{},
    };
}

/// Reopen a saved tab: its server, or its profile (or the default one, if
/// that shell is gone) in its folder (or the usual one, if the folder is
/// gone).
pub fn openSavedTab(self: *Window, tab: session.Tab) void {
    if (tab.server.len > 0) {
        const surface = openServer(self, tab.server, if (server_shell.validFolder(tab.folder)) tab.folder else null) orelse return;
        return browser_dock.rememberPages(self, surface.pane_id, tab.pages);
    }
    const folder = if (profiles.programExists(tab.folder)) tab.folder else null;
    const list = profiles.detect();
    const index = for (0..list.len) |i| {
        if (std.mem.eql(u8, list.name(i), tab.profile)) break i;
    } else list.selected(self.configuredCommand()) orelse return;
    const surface = self.openProfileIn(&list, index, folder, false) orelse return;
    browser_dock.rememberPages(self, surface.pane_id, tab.pages);
    // Claude Code was running a conversation here: type its resume into
    // the new shell, which reads it once it starts. Not in WSL, whose
    // claude would be another install.
    if (tab.claude.len == 0 or !self.app.config.@"ai-resume-claude" or surface.wsl) return;
    if (!claude_session.saved(tab.claude, folder orelse return)) return;
    var buf: [64]u8 = undefined;
    const command = claude_session.resumeCommand(&buf, tab.claude) orelse return;
    const msg = termio.Message.writeReq(self.app.core_app.alloc, command) catch return;
    surface.core_surface.io.queueMessage(msg, .unlocked);
}

pub fn openServer(self: *Window, destination: []const u8, folder: ?[]const u8) ?*Surface {
    return openServerAfter(self, destination, folder, "");
}

pub fn openServerAfter(self: *Window, destination: []const u8, folder: ?[]const u8, before: []const u8) ?*Surface {
    // The address may come from a file or a process, and must not be
    // read by ssh as an option.
    if (!servers.valid(destination)) {
        log.warn("not an ssh destination: {s}", .{destination});
        return null;
    }
    const argv = self.app.core_app.alloc.create(server_shell.Argv) catch return null;
    defer self.app.core_app.alloc.destroy(argv);
    const command: configpkg.Command = .{ .direct = (server_shell.build(argv, destination, folder, before) orelse return null).slice() };
    const surface = self.addTabWithOptions(.{
        .context = .tab,
        .command = &command,
        .icon = self.app.profile_icons.get("ssh.exe", self.tabIconSize()),
        .profile_name = "SSH",
    }) catch |err| {
        log.err("failed to open ssh to {s}: {}", .{ destination, err });
        return null;
    };
    // File it under Servers now, not at the next poll.
    _ = surface.setSshHost(destination);
    surface.opened_on_server = true;
    surface.setServerFolder(folder orelse "");
    if (self.app.recent_servers.add(destination)) self.app.saveSession();
    self.invalidateTabBar();
    return surface;
}

/// Poll each tab for an SSH session, so the sidebar can file it under
/// Servers, and for a Claude Code conversation, so a reopened tab can
/// resume it. One process snapshot serves every tab.
pub fn pollTabs(self: *Window) void {
    server_tunnel.prune(self);
    const procs = process_tree.Processes.take();
    var changed = false;
    for (0..self.tab_count) |i| {
        const surface = self.tab_active_surface[i];
        if (!surface.core_surface_ready) continue;
        const pid = surface.core_surface.io.processId() orelse continue;
        if (surface.setClaudeSession(claude_session.find(&procs, pid))) changed = true;
        if (surface.opened_on_server) continue;
        var buf: [128]u8 = undefined;
        const host = ssh.host(&procs, pid, &buf) orelse "";
        if (!surface.setSshHost(host)) continue;
        changed = true;
        // Servers reached by typing ssh are offered again later.
        _ = self.app.recent_servers.add(surface.sshHost());
    }
    if (!changed) return;
    self.invalidateTabBar();
    self.app.saveSession();
}

/// Ask for a folder, then open a tab there: profile `index` when given,
/// else the default shell of `section`.
pub fn pickFolderAndOpen(self: *Window, section: tab_sidebar.Section, index: ?usize) void {
    var buf: [1024]u8 = undefined;
    const folder = pickFolder(self, &buf) orelse return;
    openInSection(self, section, index, folder);
}

/// Windows' folder picker, starting where the active tab is.
fn pickFolder(self: *Window, buf: *[1024]u8) ?[]const u8 {
    const hwnd = self.hwnd orelse return null;
    const start = if (self.getActiveSurface()) |s| s.folderPath() else "";
    return folder_picker.pick(hwnd, profiles.data.sidebar.pick_folder, start, buf);
}

/// Open profile `index` in `folder`, or without one the default shell of
/// `section`: the first WSL distribution for WSL, else the configured shell.
pub fn openInSection(self: *Window, section: tab_sidebar.Section, index: ?usize, folder: []const u8) void {
    const list = profiles.detect();
    const default = (if (section == .wsl) list.first(.wsl) else null) orelse list.selected(self.configuredCommand()) orelse return;
    _ = self.openProfileIn(&list, index orelse default, folder, false);
}

/// The shell menu dropped below the sidebar arrow `arrow`. Returns the
/// profile picked.
pub fn sidebarProfileMenu(self: *Window, arrow: tab_sidebar.Target, list: *const profiles.List) ?usize {
    const hwnd = self.hwnd orelse return null;
    const corner = pressSidebarArrow(self, arrow) orelse return null;
    defer releaseSidebarArrow(self);
    return new_tab_menu.show(hwnd, corner, list, list.selected(self.configuredCommand()), &self.app.profile_icons, self.scale, strip_mouse.menusDark(self));
}

const first_scan_wait_ms = 2_000;

const PickedServer = struct {
    name: servers.Name,
    nearby: bool,
};

/// The server menu dropped below Servers' arrow. Returns the server picked.
fn sidebarServerMenu(self: *Window, arrow: tab_sidebar.Target) ?PickedServer {
    const hwnd = self.hwnd orelse return null;
    const corner = pressSidebarArrow(self, arrow) orelse return null;
    defer releaseSidebarArrow(self);
    nearby_servers.refresh();
    nearby_servers.awaitFirst(first_scan_wait_ms);
    const configured = servers.Configured.read(self.app.core_app.alloc);
    var configured_names: [servers.Configured.capacity][]const u8 = undefined;
    var recent_names: [servers.Recent.capacity][]const u8 = undefined;
    const found = nearby_servers.snapshot();
    var nearby_names: [nearby_servers.capacity][]const u8 = undefined;
    var nearby_labels: [nearby_servers.capacity][]const u8 = undefined;
    var label_bufs: [nearby_servers.capacity][servers.max_len * 2 + 8]u8 = undefined;
    for (found.list(), 0..) |*server, i| {
        nearby_names[i] = server.address.text();
        nearby_labels[i] = server.label(&label_bufs[i]);
    }
    const n = found.len;
    const picked = new_tab_menu.showServers(hwnd, corner, configured.names(&configured_names), self.app.recent_servers.names(&recent_names), nearby_names[0..n], nearby_labels[0..n], found.scanning, strip_mouse.menusDark(self)) orelse return null;
    // The menu's names live in lists that end with this call.
    return .{ .name = .init(picked.name), .nearby = picked.nearby };
}

fn askUserFor(self: *Window, address: []const u8) void {
    self.server_field_address = .init(address);
    focusServerField(self, true);
}

/// Light `arrow` while its menu is open, and return where the menu drops,
/// in screen pixels.
pub fn pressSidebarArrow(self: *Window, arrow: tab_sidebar.Target) ?w32.POINT {
    const hwnd = self.hwnd orelse return null;
    const spot = for (self.sidebar_spots.items[0..self.sidebar_spots.len]) |spot| {
        if (spot.target.eql(arrow)) break spot;
    } else return null;
    const sidebar = sidebarRect(self);
    var corner: w32.POINT = .{ .x = sidebar.left + spot.rect.left, .y = sidebar.top + spot.rect.bottom + @as(i32, @intFromFloat(@round(4 * self.scale))) };
    _ = w32.ClientToScreen(hwnd, &corner);
    self.sidebar_pressed = arrow;
    self.invalidateTabBar();
    return corner;
}

pub fn releaseSidebarArrow(self: *Window) void {
    self.sidebar_pressed = .none;
    self.invalidateTabBar();
}

/// The sidebar's rectangle in client coordinates.
pub fn sidebarRect(self: *const Window) w32.RECT {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.hwnd) |hwnd| _ = w32.GetClientRect(hwnd, &client);
    return .{ .left = 0, .top = self.tabBarHeight(), .right = self.sidebarWidth(), .bottom = client.bottom };
}

pub fn inSidebar(self: *const Window, x: i32, y: i32) bool {
    const r = sidebarRect(self);
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}
