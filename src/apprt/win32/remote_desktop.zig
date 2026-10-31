const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const profiles = @import("profiles.zig");
const ssh_settings = @import("ssh_settings.zig");
const tcp_probe = @import("tcp_probe.zig");

const log = std.log.scoped(.remote_desktop);
const text = profiles.data.sidebar.server_menu;

pub const Outcome = enum { launched, no_desktop, unknown_host };

pub fn open(alloc: std.mem.Allocator, destination: []const u8) Outcome {
    const settings = ssh_settings.read(alloc, destination) orelse {
        log.warn("ssh -G gave nothing for {s}", .{destination});
        return .unknown_host;
    };
    const host = settings.hostname.text();
    if (!tcp_probe.reachable(host, text.desktop_port, text.desktop_timeout_ms)) return .no_desktop;
    launch(host);
    return .launched;
}

fn launch(host: []const u8) void {
    var system: [260:0]u16 = undefined;
    const dir_len = w32.GetSystemDirectoryW(&system, system.len);
    if (dir_len == 0 or dir_len > system.len - 16) return;
    const exe = std.unicode.utf8ToUtf16LeStringLiteral("\\mstsc.exe");
    @memcpy(system[dir_len..][0..exe.len], exe);
    system[dir_len + exe.len] = 0;

    var params_utf8: [300]u8 = undefined;
    const params = std.fmt.bufPrint(&params_utf8, "/v:{s}", .{host}) catch return;
    var params_wide: [300:0]u16 = undefined;
    const n = wide_string.fromUtf8(&params_wide, params);
    params_wide[n] = 0;
    const result = w32.ShellExecuteW(null, null, &system, &params_wide, null, 1);
    if (result <= 32) log.warn("mstsc did not start: {d}", .{result});
}
