const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const menu_theme = @import("menu_theme.zig");
const server_probe = @import("server_probe.zig");
const server_query = @import("server_query.zig");
const server_shell = @import("server_shell.zig");
const server_tunnel = @import("server_tunnel.zig");
const strip_mouse = @import("strip_mouse.zig");
const tools = @import("server_tools.zig").data;
const Window = @import("Window.zig");

pub const Outcome = enum { opened, cancelled, sign_in_needed, missing, failed };

const max_apps = 400;
const max_exec = 1024;
const id_first = 1000;

const App = struct {
    kind: enum { app, desktop },
    category: ?usize,
    name: []const u8,
    exec: []const u8,
};

const entry_program =
    "FNR==1{s=0;n=\"\";e=\"\";c=\"\";h=0} " ++
    "/^\\[/{s=($0==\"[Desktop Entry]\");next} " ++
    "s&&$1==\"Name\"&&n==\"\"{n=substr($0,6)} " ++
    "s&&$1==\"Exec\"&&e==\"\"{e=substr($0,6)} " ++
    "s&&$1==\"Categories\"&&c==\"\"{c=substr($0,12)} " ++
    "s&&($1==\"NoDisplay\"||$1==\"Hidden\"||$1==\"Terminal\")&&$2==\"true\"{h=1} " ++
    "s&&k==\"app\"&&$1==\"Type\"&&$2!=\"Application\"{h=1} " ++
    "END{if(!h&&n!=\"\"&&e!=\"\")print k \"\\t\" c \"\\t\" n \"\\t\" e}";
const list_script =
    "a='" ++ entry_program ++ "'; " ++
    "for f in /usr/share/xsessions/*.desktop; do [ -f \"$f\" ] && awk -F= -v k=desktop \"$a\" \"$f\"; done; " ++
    "for f in /usr/share/applications/*.desktop \"$HOME\"/.local/share/applications/*.desktop; do [ -f \"$f\" ] && awk -F= -v k=app \"$a\" \"$f\"; done; true";

pub fn open(self: *Window, destination: []const u8, point: w32.POINT) Outcome {
    const alloc = self.app.core_app.alloc;
    const probe = switch (server_probe.read(alloc, destination)) {
        .probe => |p| p,
        .sign_in_needed => return .sign_in_needed,
        .unreachable_server => return .failed,
    };
    if (!probe.has_apps) return .missing;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (!server_query.run(alloc, destination, list_script, &out)) return .failed;
    var apps: [max_apps]App = undefined;
    const listed = parse(out.items, &apps);
    const picked = pick(self, point, listed) orelse return .cancelled;
    return launch(self, destination, &probe, picked);
}

fn parse(output: []const u8, out: *[max_apps]App) []App {
    var n: usize = 0;
    var lines = std.mem.tokenizeAny(u8, output, "\r\n");
    while (lines.next()) |line| {
        if (n == out.len) break;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse continue;
        const categories = fields.next() orelse continue;
        const name = std.mem.trim(u8, fields.next() orelse continue, " ");
        const exec = std.mem.trim(u8, fields.rest(), " ");
        if (name.len == 0 or exec.len == 0 or exec.len > max_exec or !printable(name) or !printable(exec)) continue;
        const duplicate = for (out[0..n]) |a| {
            if (std.mem.eql(u8, a.name, name)) break true;
        } else false;
        if (duplicate) continue;
        out[n] = .{
            .kind = if (std.mem.eql(u8, kind, "desktop")) .desktop else .app,
            .category = mainCategory(categories),
            .name = name,
            .exec = exec,
        };
        n += 1;
    }
    std.mem.sort(App, out[0..n], {}, byName);
    return out[0..n];
}

fn byName(_: void, a: App, b: App) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn printable(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn mainCategory(categories: []const u8) ?usize {
    var it = std.mem.tokenizeScalar(u8, categories, ';');
    while (it.next()) |category| {
        for (tools.apps.categories, 0..) |known, i| {
            if (std.mem.eql(u8, known.key, category)) return i;
        }
    }
    return null;
}

fn pick(self: *Window, point: w32.POINT, apps: []const App) ?*const App {
    const hwnd = self.hwnd orelse return null;
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    if (apps.len == 0) append(menu, w32.MF_GRAYED, 0, tools.apps.none);

    for (apps, 0..) |*app, i| {
        if (app.kind == .desktop) append(menu, w32.MF_STRING, id_first + i, app.name);
    }
    for (apps) |app| {
        if (app.kind != .desktop) continue;
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        break;
    }
    for (tools.apps.categories, 0..) |category, c| submenu(menu, category.label, apps, c);
    submenu(menu, tools.apps.other, apps, null);

    menu_theme.apply(strip_mouse.menusDark(self));
    const picked: usize = @intCast(@max(0, w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, point.x, point.y, hwnd, null)));
    if (picked < id_first or picked - id_first >= apps.len) return null;
    return &apps[picked - id_first];
}

fn submenu(menu: w32.HMENU, label: []const u8, apps: []const App, category: ?usize) void {
    const sub = w32.CreatePopupMenu() orelse return;
    var count: usize = 0;
    for (apps, 0..) |app, i| {
        if (app.kind != .app or app.category != category) continue;
        append(sub, w32.MF_STRING, id_first + i, app.name);
        count += 1;
    }
    if (count == 0) {
        _ = w32.DestroyMenu(sub);
        return;
    }
    var wide: [128]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, label);
    _ = w32.AppendMenuW(menu, w32.MF_POPUP, @intFromPtr(sub), @ptrCast(&wide));
}

fn append(menu: w32.HMENU, flags: u32, id: usize, label: []const u8) void {
    var wide: [256]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, label);
    _ = w32.AppendMenuW(menu, flags, id, @ptrCast(&wide));
}

fn launch(self: *Window, destination: []const u8, probe: *const server_probe.Probe, app: *const App) Outcome {
    const alloc = self.app.core_app.alloc;
    const id = w32.GetTickCount64() % 1_000_000_000;
    var socket_buf: [server_shell.max_folder_len + 96]u8 = undefined;
    const socket = std.fmt.bufPrint(&socket_buf, "{s}/{s}/apps/web-{d}.sock", .{ probe.home(), tools.runtime_folder, id }) catch return .failed;

    var script: std.Io.Writer.Allocating = .init(alloc);
    defer script.deinit();
    writeSession(&script.writer, socket, app) catch return .failed;
    return switch (server_tunnel.start(self, destination, .app, socket, script.written())) {
        .port => |port| {
            server_tunnel.show(self, port, "/" ++ tools.apps.page);
            return .opened;
        },
        .missing => .missing,
        .sign_in_needed => .sign_in_needed,
        .failed => .failed,
    };
}

fn writeSession(w: *std.Io.Writer, socket: []const u8, app: *const App) !void {
    const a = tools.apps;
    try w.writeAll("umask 077; r=\"$HOME/" ++ tools.runtime_folder ++ "\"; d=\"$r/apps\"; mkdir -p \"$d\"; chmod 700 \"$r\" \"$d\"; " ++
        "X=" ++ server_probe.vnc_server ++ "; " ++
        "[ -n \"$X\" ] && command -v websockify >/dev/null && [ -f /usr/share/novnc/vnc.html ] || { echo " ++ server_tunnel.missing_marker ++ "; exit 0; }; " ++
        std.fmt.comptimePrint("n={d}; ", .{a.first_display}) ++
        "while [ -e /tmp/.X11-unix/X$n ] || [ -e /tmp/.X$n-lock ]; do n=$((n+1)); done; " ++
        "a=\"$d/auth$n\"; s=\"$d/vnc$n.sock\"; w=");
    try server_shell.writeQuoted(w, socket);
    try w.writeAll("; rm -f \"$a\" \"$s\" \"$w\"; : >\"$a\"; " ++
        "ax=; command -v xauth >/dev/null && xauth -f \"$a\" add :$n . \"$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')\" && ax=\"-auth $a\"; " ++
        "\"$X\" :$n $ax -geometry " ++ a.screen ++ " -depth 24 -SecurityTypes None -rfbport -1 -rfbunixpath \"$s\" -AlwaysShared >\"$d/x$n.log\" 2>&1 & xp=$!; " ++
        "i=0; while [ ! -S \"$s\" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; " ++
        "[ -S \"$s\" ] || { cat \"$d/x$n.log\"; kill $xp; exit 1; }; " ++
        "websockify --web /usr/share/novnc --unix-listen=\"$w\" --unix-target=\"$s\" >\"$d/ws$n.log\" 2>&1 & wp=$!; " ++
        "i=0; while [ ! -S \"$w\" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; " ++
        "[ -S \"$w\" ] || { cat \"$d/ws$n.log\"; kill $xp $wp; exit 1; }; " ++
        "export DISPLAY=:$n XAUTHORITY=\"$a\"; ");
    if (app.kind == .app) try w.writeAll("command -v matchbox-window-manager >/dev/null && { matchbox-window-manager -use_titlebar no >/dev/null 2>&1 & }; ");
    var exec_buf: [max_exec]u8 = undefined;
    try w.writeAll("c=");
    try server_shell.writeQuoted(w, withoutFieldCodes(app.exec, &exec_buf));
    try w.writeAll("; if command -v dbus-run-session >/dev/null; then dbus-run-session -- sh -c \"$c\"; else sh -c \"$c\"; fi >\"$d/app$n.log\" 2>&1 & " ++
        "echo " ++ server_tunnel.ready_marker ++ "; read -r _; kill $wp $xp 2>/dev/null; rm -f \"$a\" \"$s\" \"$w\"");
}

fn withoutFieldCodes(exec: []const u8, exec_buf: *[max_exec]u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            if (exec[i + 1] == '%') exec_buf[n] = '%' else {
                i += 1;
                continue;
            }
            n += 1;
            i += 1;
            continue;
        }
        exec_buf[n] = exec[i];
        n += 1;
    }
    return std.mem.trim(u8, exec_buf[0..n], " ");
}

pub fn writeInstall(w: *std.Io.Writer) !void {
    try w.writeAll("sudo apt-get install -y " ++ tools.apps.packages ++ " && printf '%s\\n' ");
    try server_shell.writeQuoted(w, tools.apps.installed);
    try w.writeAll("; ");
}
