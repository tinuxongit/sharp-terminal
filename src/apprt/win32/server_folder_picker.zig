const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const menu_theme = @import("menu_theme.zig");
const command_line = @import("command_line.zig");
const profiles = @import("profiles.zig");
const servers = @import("servers.zig");
const server_shell = @import("server_shell.zig");
const HiddenCli = @import("HiddenCli.zig");

const text = profiles.data.sidebar.server_menu;
const max_listed = 200;
const id_open_here = 1;
const id_parent = 2;
const id_first_folder = 100;

pub const Picked = union(enum) {
    folder: []const u8,
    cancelled,
    unreachable_without_password,
};

pub fn pick(alloc: std.mem.Allocator, owner: w32.HWND, point: w32.POINT, destination: []const u8, start: []const u8, out: *[server_shell.max_folder_len]u8, dark: bool) Picked {
    var dir_buf: [server_shell.max_folder_len]u8 = undefined;
    var dir: []const u8 = start;
    while (true) {
        var listing = list(alloc, destination, dir) orelse return .unreachable_without_password;
        defer listing.deinit(alloc);
        const here = listing.here();
        switch (show(owner, point, &listing, dark)) {
            .cancelled => return .cancelled,
            .open_here => {
                @memcpy(out[0..here.len], here);
                return .{ .folder = out[0..here.len] };
            },
            .parent => {
                const cut = std.mem.lastIndexOfScalar(u8, here, '/') orelse 0;
                dir = if (cut == 0) "/" else here[0..cut];
                @memcpy(dir_buf[0..dir.len], dir);
                dir = dir_buf[0..dir.len];
            },
            .folder => |name| {
                const joined = std.fmt.bufPrint(&dir_buf, "{s}{s}{s}", .{ here, if (std.mem.endsWith(u8, here, "/")) "" else "/", name }) catch return .cancelled;
                if (!server_shell.validFolder(joined)) return .cancelled;
                dir = joined;
            },
        }
    }
}

const Listing = struct {
    output: std.ArrayList(u8),
    here_end: usize,
    folders: [max_listed][]const u8 = undefined,
    folder_count: usize = 0,

    fn here(self: *const Listing) []const u8 {
        return self.output.items[0..self.here_end];
    }

    fn deinit(self: *Listing, alloc: std.mem.Allocator) void {
        self.output.deinit(alloc);
    }
};

fn list(alloc: std.mem.Allocator, destination: []const u8, dir: []const u8) ?Listing {
    if (!servers.valid(destination)) return null;
    var script_buf: [server_shell.max_folder_len * 4 + 64]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buf);
    if (dir.len > 0) {
        script.writeAll("cd ") catch return null;
        server_shell.writeQuoted(&script, dir) catch return null;
        script.writeAll(" 2>/dev/null || cd; ") catch return null;
    } else {
        script.writeAll("cd; ") catch return null;
    }
    script.writeAll("pwd; ls -1Ap") catch return null;

    var command_buf: [script_buf.len * 2 + 256]u8 = undefined;
    var command: std.Io.Writer = .fixed(&command_buf);
    command.print("ssh.exe -o BatchMode=yes -o ConnectTimeout=5 {s} ", .{destination}) catch return null;
    command_line.quote(&command, "", script.buffered()) catch return null;

    const previous_cursor = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_WAIT));
    defer _ = w32.SetCursor(previous_cursor);
    var cli = HiddenCli.startWithin(command.buffered(), 15_000) orelse return null;
    defer cli.end();
    var listing: Listing = .{ .output = .empty, .here_end = 0 };
    cli.readAll(alloc, &listing.output);

    const items = listing.output.items;
    const first_end = std.mem.indexOfScalar(u8, items, '\n') orelse items.len;
    const first = std.mem.trimEnd(u8, items[0..first_end], "\r");
    if (!server_shell.validFolder(first)) {
        listing.deinit(alloc);
        return null;
    }
    listing.here_end = first.len;
    var lines = std.mem.tokenizeAny(u8, items[@min(first_end + 1, items.len)..], "\r\n");
    while (lines.next()) |line| {
        if (listing.folder_count == max_listed) break;
        if (line.len < 2 or line[line.len - 1] != '/' or line[0] == '.') continue;
        listing.folders[listing.folder_count] = line[0 .. line.len - 1];
        listing.folder_count += 1;
    }
    return listing;
}

const Choice = union(enum) {
    cancelled,
    open_here,
    parent,
    folder: []const u8,
};

fn show(owner: w32.HWND, point: w32.POINT, listing: *const Listing, dark: bool) Choice {
    const menu = w32.CreatePopupMenu() orelse return .cancelled;
    defer _ = w32.DestroyMenu(menu);
    var label_buf: [server_shell.max_folder_len + 64]u8 = undefined;
    const open_label = std.fmt.bufPrint(&label_buf, "{s}  {s}", .{ text.open_here, listing.here() }) catch text.open_here;
    append(menu, w32.MF_STRING, id_open_here, open_label);
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    if (!std.mem.eql(u8, listing.here(), "/")) append(menu, w32.MF_STRING, id_parent, text.parent_folder);
    for (listing.folders[0..listing.folder_count], 0..) |name, i| append(menu, w32.MF_STRING, id_first_folder + i, name);
    if (listing.folder_count == 0) append(menu, w32.MF_GRAYED, 0, text.no_folders);

    menu_theme.apply(dark);
    const picked: usize = @intCast(@max(0, w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, owner, null)));
    return switch (picked) {
        0 => .cancelled,
        id_open_here => .open_here,
        id_parent => .parent,
        else => if (picked >= id_first_folder and picked - id_first_folder < listing.folder_count) .{ .folder = listing.folders[picked - id_first_folder] } else .cancelled,
    };
}

fn append(menu: w32.HMENU, flags: u32, id: usize, label: []const u8) void {
    var wide: [server_shell.max_folder_len + 64]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, label);
    _ = w32.AppendMenuW(menu, flags, id, @ptrCast(&wide));
}
