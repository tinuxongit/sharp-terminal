const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const wide_string = @import("wide_string.zig");
const command_line = @import("command_line.zig");
const servers = @import("servers.zig");
const HiddenCli = @import("HiddenCli.zig");
const server_query = @import("server_query.zig");
const tcp_probe = @import("tcp_probe.zig");
const browser_dock = @import("browser_dock.zig");
const browser_chats = @import("browser_chats.zig");
const tools = @import("server_tools.zig").data;
const Window = @import("Window.zig");

const windows = internal_os.windows;
const kernel32 = windows.exp.kernel32;
const log = std.log.scoped(.server_tunnel);

pub const ready_marker = "SHARP-READY";
pub const missing_marker = "SHARP-MISSING";
const max_tunnels = 16;
const unseen_grace_ms = 30_000;

pub const Kind = enum { files, app };

pub const Started = union(enum) {
    port: u16,
    missing,
    sign_in_needed,
    failed,
};

const Tunnel = struct {
    window: *Window,
    destination: servers.Name,
    kind: Kind,
    cli: HiddenCli,
    port: u16,
    watched: bool = false,
    seen: bool = false,
    missed: u8 = 0,
};

var tunnels: [max_tunnels]?Tunnel = @splat(null);
var job: ?windows.HANDLE = null;

pub fn running(window: *Window, destination: []const u8, kind: Kind) ?u16 {
    for (&tunnels) |*slot| {
        const tunnel = &(slot.* orelse continue);
        if (tunnel.window != window or tunnel.kind != kind or !std.mem.eql(u8, tunnel.destination.text(), destination)) continue;
        if (exited(tunnel)) {
            end(slot);
            continue;
        }
        return tunnel.port;
    }
    return null;
}

pub fn start(window: *Window, destination: []const u8, kind: Kind, remote_socket: []const u8, script: []const u8) Started {
    const alloc = window.app.core_app.alloc;
    if (!servers.valid(destination) or std.mem.indexOfAny(u8, remote_socket, ": ") != null) return .failed;
    const slot = for (&tunnels) |*slot| {
        if (slot.* == null) break slot;
    } else return .failed;
    const port = freePort() orelse return .failed;

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    command.writer.print("ssh.exe -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -T -L {s}:{d}:{s} {s} ", .{ tools.tunnel_address, port, remote_socket, destination }) catch return .failed;
    command_line.quote(&command.writer, "", script) catch return .failed;

    const previous_cursor = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_WAIT));
    defer _ = w32.SetCursor(previous_cursor);
    var cli = HiddenCli.startWithin(command.written(), tools.start_timeout_ms) orelse return .failed;
    if (endsWithSharp()) |j| _ = kernel32.AssignProcessToJobObject(j, cli.process);

    var said: std.ArrayList(u8) = .empty;
    defer said.deinit(alloc);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);
    while (cli.readLine(alloc, &pending)) |line| {
        defer alloc.free(line);
        if (std.mem.indexOf(u8, line, ready_marker) != null) {
            slot.* = .{ .window = window, .destination = .init(destination), .kind = kind, .cli = cli, .port = port };
            return .{ .port = port };
        }
        if (std.mem.indexOf(u8, line, missing_marker) != null) {
            cli.end();
            return .missing;
        }
        said.appendSlice(alloc, line) catch {};
        said.append(alloc, '\n') catch {};
    }
    cli.end();
    log.warn("tunnel to {s} didn't start: {s}", .{ destination, said.items });
    return if (server_query.deniedPassword(said.items)) .sign_in_needed else .failed;
}

pub fn show(window: *Window, port: u16, path: []const u8) void {
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}{s}", .{ tools.tunnel_address, port, path }) catch return;
    if (browser_dock.open(window)) {
        if (browser_dock.panelOf(window)) |panel| {
            if (panel.openTab(browser_chats.paneOwner(window), url) != null) {
                watch(window, port);
                return;
            }
        }
    }
    var wide: [1024:0]u16 = undefined;
    wide[wide_string.fromUtf8(&wide, url)] = 0;
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), &wide, null, null, 1);
}

fn watch(window: *Window, port: u16) void {
    for (&tunnels) |*slot| {
        const tunnel = &(slot.* orelse continue);
        if (tunnel.window == window and tunnel.port == port) tunnel.watched = true;
    }
}

pub fn ownsPage(url: []const u8) bool {
    const prefix = "http://" ++ tools.tunnel_address ++ ":";
    return std.ascii.startsWithIgnoreCase(url, prefix);
}

pub fn prune(window: *Window) void {
    const now = w32.GetTickCount64();
    for (&tunnels) |*slot| {
        const tunnel = &(slot.* orelse continue);
        if (tunnel.window != window) continue;
        if (exited(tunnel)) {
            end(slot);
            continue;
        }
        if (!tunnel.watched) continue;
        if (pageOpen(window, tunnel.port)) {
            tunnel.seen = true;
            tunnel.missed = 0;
            continue;
        }
        if (!tunnel.seen and now - tunnel.cli.started_ms < unseen_grace_ms) continue;
        tunnel.missed += 1;
        if (tunnel.missed >= tools.missed_polls_to_end) end(slot);
    }
}

pub fn endFor(window: *Window) void {
    for (&tunnels) |*slot| {
        const tunnel = &(slot.* orelse continue);
        if (tunnel.window == window) end(slot);
    }
}

fn pageOpen(window: *Window, port: u16) bool {
    const panel = window.browser orelse return false;
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "http://{s}:{d}/", .{ tools.tunnel_address, port }) catch return false;
    for (panel.tabs()) |tab| {
        var buf: [2048]u8 = undefined;
        const url = tab.source(&buf) orelse continue;
        if (std.ascii.startsWithIgnoreCase(url, prefix)) return true;
    }
    return false;
}

fn exited(tunnel: *const Tunnel) bool {
    return kernel32.WaitForSingleObject(tunnel.cli.process, 0) == 0;
}

fn end(slot: *?Tunnel) void {
    var tunnel = slot.* orelse return;
    tunnel.cli.end();
    slot.* = null;
}

fn endsWithSharp() ?windows.HANDLE {
    if (job) |j| return j;
    const j = kernel32.CreateJobObjectW(null, null) orelse return null;
    var limits: w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{ .LimitFlags = w32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE };
    if (kernel32.SetInformationJobObject(j, w32.JobObjectExtendedLimitInformation, &limits, @sizeOf(w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == windows.FALSE) {
        _ = kernel32.CloseHandle(j);
        return null;
    }
    job = j;
    return j;
}

fn freePort() ?u16 {
    const addr = tcp_probe.resolve(tools.tunnel_address) orelse return null;
    const s = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
    if (s == w32.INVALID_SOCKET) return null;
    defer _ = w32.closesocket(s);
    var bound: w32.sockaddr_in = .{ .port = 0, .addr = addr };
    if (w32.bind(s, &bound, @sizeOf(w32.sockaddr_in)) != 0) return null;
    var len: i32 = @sizeOf(w32.sockaddr_in);
    if (w32.getsockname(s, &bound, &len) != 0) return null;
    return std.mem.bigToNative(u16, bound.port);
}
