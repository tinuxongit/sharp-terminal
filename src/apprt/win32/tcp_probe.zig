const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");

pub const max_addresses = 1024;

var winsock_ready: std.atomic.Value(bool) = .init(false);

fn startWinsock() void {
    if (winsock_ready.load(.acquire)) return;
    var data: w32.WSADATA = undefined;
    if (w32.WSAStartup(0x0202, &data) == 0) winsock_ready.store(true, .release);
}

pub fn resolve(host: []const u8) ?u32 {
    startWinsock();
    var wide: [256:0]u16 = undefined;
    const len = wide_string.fromUtf8(&wide, host);
    if (len == 0) return null;
    wide[len] = 0;
    const hints: w32.ADDRINFOW = .{ .ai_flags = 0, .ai_family = w32.AF_INET, .ai_socktype = w32.SOCK_STREAM, .ai_protocol = w32.IPPROTO_TCP, .ai_addrlen = 0, .ai_canonname = null, .ai_addr = null, .ai_next = null };
    var result: ?*w32.ADDRINFOW = null;
    if (w32.GetAddrInfoW(&wide, null, &hints, &result) != 0) return null;
    const first = result orelse return null;
    defer w32.FreeAddrInfoW(first);
    const addr = first.ai_addr orelse return null;
    return addr.addr;
}

pub fn reachable(host: []const u8, port: u16, timeout_ms: u32) bool {
    const addr = resolve(host) orelse return false;
    var found = [1]bool{false};
    answering(&.{addr}, port, "", timeout_ms, &found);
    return found[0];
}

pub fn answering(addrs: []const u32, port: u16, greeting: []const u8, timeout_ms: u32, found: []bool) void {
    startWinsock();
    const n = @min(addrs.len, max_addresses, found.len);
    var sockets: [max_addresses]w32.SOCKET = undefined;
    var connected: [max_addresses]bool = @splat(false);
    var opened: usize = 0;
    defer for (sockets[0..opened]) |s| {
        if (s != w32.INVALID_SOCKET) _ = w32.closesocket(s);
    };
    for (addrs[0..n], 0..) |addr, i| {
        found[i] = false;
        sockets[i] = startConnect(addr, port);
        opened = i + 1;
    }

    const deadline = w32.GetTickCount64() + timeout_ms;
    waitFor(sockets[0..n], w32.POLLWRNORM, deadline, &connected);
    if (greeting.len == 0) {
        for (0..n) |i| found[i] = connected[i];
        return;
    }
    var readable: [max_addresses]bool = @splat(false);
    var greeters: [max_addresses]w32.SOCKET = undefined;
    for (0..n) |i| greeters[i] = if (connected[i]) sockets[i] else w32.INVALID_SOCKET;
    waitFor(greeters[0..n], w32.POLLRDNORM, deadline + timeout_ms, &readable);
    for (0..n) |i| {
        if (!readable[i]) continue;
        var buf: [64]u8 = undefined;
        const got = w32.recv(sockets[i], &buf, buf.len, 0);
        if (got > 0) found[i] = std.mem.startsWith(u8, buf[0..@intCast(got)], greeting);
    }
}

fn startConnect(addr: u32, port: u16) w32.SOCKET {
    const s = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
    if (s == w32.INVALID_SOCKET) return s;
    var nonblocking: u32 = 1;
    _ = w32.ioctlsocket(s, w32.FIONBIO, &nonblocking);
    const target: w32.sockaddr_in = .{ .port = std.mem.nativeToBig(u16, port), .addr = addr };
    _ = w32.connect(s, &target, @sizeOf(w32.sockaddr_in));
    return s;
}

fn waitFor(sockets: []const w32.SOCKET, events: i16, deadline: u64, ready: *[max_addresses]bool) void {
    var fds: [max_addresses]w32.WSAPOLLFD = undefined;
    var index: [max_addresses]usize = undefined;
    var pending: usize = 0;
    for (sockets, 0..) |s, i| {
        if (s == w32.INVALID_SOCKET) continue;
        fds[pending] = .{ .fd = s, .events = events };
        index[pending] = i;
        pending += 1;
    }
    while (pending > 0) {
        const now = w32.GetTickCount64();
        if (now >= deadline) return;
        const r = w32.WSAPoll(&fds, @intCast(pending), @intCast(deadline - now));
        if (r <= 0) return;
        var i: usize = 0;
        while (i < pending) {
            if (fds[i].revents == 0) {
                i += 1;
                continue;
            }
            ready[index[i]] = fds[i].revents & events != 0 and noError(fds[i].fd);
            pending -= 1;
            fds[i] = fds[pending];
            index[i] = index[pending];
        }
    }
}

fn noError(s: w32.SOCKET) bool {
    var err: i32 = 0;
    var len: i32 = @sizeOf(i32);
    if (w32.getsockopt(s, w32.SOL_SOCKET, w32.SO_ERROR, @ptrCast(&err), &len) != 0) return false;
    return err == 0;
}

pub fn nameOf(addr: u32, out: []u8) ?[]const u8 {
    startWinsock();
    const target: w32.sockaddr_in = .{ .port = 0, .addr = addr };
    var wide: [256]u16 = undefined;
    if (w32.GetNameInfoW(&target, @sizeOf(w32.sockaddr_in), &wide, wide.len, null, 0, w32.NI_NAMEREQD) != 0) return null;
    const len = std.mem.indexOfScalar(u16, &wide, 0) orelse return null;
    const n = wide_string.toUtf8(out, wide[0..len]);
    return out[0..n];
}

pub fn formatAddress(addr: u32, out: []u8) []const u8 {
    const b: [4]u8 = @bitCast(addr);
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch "";
}
