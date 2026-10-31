const std = @import("std");
const global = @import("../../global.zig");
const w32 = @import("win32.zig");
const servers = @import("servers.zig");
const tcp_probe = @import("tcp_probe.zig");
const ssh_settings = @import("ssh_settings.zig");

const log = std.log.scoped(.nearby_servers);

pub const capacity = 32;
const rescan_after_ms = 60_000;
const connect_timeout_ms = 800;
const max_subnets = 4;

pub const Server = struct {
    address: servers.Name = .{},
    name: servers.Name = .{},

    pub fn label(self: *const Server, buf: []u8) []const u8 {
        if (self.name.len == 0) return self.address.text();
        return std.fmt.bufPrint(buf, "{s}  ({s})", .{ self.name.text(), self.address.text() }) catch self.address.text();
    }
};

pub const Found = struct {
    items: [capacity]Server = undefined,
    len: usize = 0,
    scanning: bool = false,

    pub fn list(self: *const Found) []const Server {
        return self.items[0..self.len];
    }
};

var lock: std.Io.Mutex = .init;
var latest: Found = .{};
var last_scan_ms: u64 = 0;
var running = false;

pub fn snapshot() Found {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    return latest;
}

pub fn refresh() void {
    {
        lock.lockUncancelable(global.io());
        defer lock.unlock(global.io());
        const now = w32.GetTickCount64();
        if (running or (last_scan_ms != 0 and now - last_scan_ms < rescan_after_ms)) return;
        running = true;
        latest.scanning = true;
        last_scan_ms = now;
    }
    const thread = std.Thread.spawn(.{}, scan, .{}) catch |err| {
        log.warn("failed to start the network scan: {}", .{err});
        lock.lockUncancelable(global.io());
        defer lock.unlock(global.io());
        running = false;
        latest.scanning = false;
        return;
    };
    thread.detach();
}

pub fn awaitFirst(timeout_ms: u64) void {
    const deadline = w32.GetTickCount64() + timeout_ms;
    while (w32.GetTickCount64() < deadline) {
        const found = snapshot();
        if (!found.scanning or found.len > 0) return;
        w32.Sleep(50);
    }
}

fn scan() void {
    var addrs: [tcp_probe.max_addresses]u32 = undefined;
    const candidates = localNeighbors(&addrs);
    var open: [tcp_probe.max_addresses]bool = undefined;
    tcp_probe.answering(candidates, 22, "SSH-", connect_timeout_ms, open[0..candidates.len]);

    var known_buf: [servers.Configured.capacity]u32 = undefined;
    const known = configuredAddresses(&known_buf);
    var next: Found = .{ .scanning = true };
    var found_addrs: [capacity]u32 = undefined;
    for (candidates, 0..) |addr, i| {
        if (!open[i] or next.len == capacity) continue;
        if (std.mem.indexOfScalar(u32, known, addr) != null) continue;
        var buf: [64]u8 = undefined;
        next.items[next.len] = .{ .address = .init(tcp_probe.formatAddress(addr, &buf)) };
        found_addrs[next.len] = addr;
        next.len += 1;
    }
    publish(next);
    for (found_addrs[0..next.len], next.items[0..next.len]) |addr, *server| {
        var name_buf: [servers.max_len]u8 = undefined;
        if (tcp_probe.nameOf(addr, &name_buf)) |name| {
            if (servers.valid(name)) server.name = .init(name);
        }
    }
    next.scanning = false;
    publish(next);
}

fn configuredAddresses(out: *[servers.Configured.capacity]u32) []const u32 {
    const alloc = std.heap.page_allocator;
    const configured = servers.Configured.read(alloc);
    var names: [servers.Configured.capacity][]const u8 = undefined;
    var n: usize = 0;
    for (configured.names(&names)) |name| {
        const settings = ssh_settings.read(alloc, name) orelse continue;
        out[n] = tcp_probe.resolve(settings.hostname.text()) orelse continue;
        n += 1;
    }
    return out[0..n];
}

fn publish(found: Found) void {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    latest = found;
    if (!found.scanning) running = false;
    last_scan_ms = w32.GetTickCount64();
}

fn localNeighbors(out: *[tcp_probe.max_addresses]u32) []const u32 {
    var table_buf: [16 * 1024]u8 align(4) = undefined;
    var size: u32 = table_buf.len;
    if (w32.GetIpAddrTable(&table_buf, &size, 0) != 0) return out[0..0];
    const count = std.mem.readInt(u32, table_buf[0..4], .little);
    const rows: [*]const w32.MIB_IPADDRROW = @ptrCast(@alignCast(&table_buf[4]));

    var n: usize = 0;
    var subnets: usize = 0;
    for (rows[0..@min(count, (table_buf.len - 4) / @sizeOf(w32.MIB_IPADDRROW))]) |row| {
        const own = std.mem.bigToNative(u32, row.dwAddr);
        if (!privateAddress(own) or subnets == max_subnets) continue;
        const mask = std.mem.bigToNative(u32, row.dwMask) | 0xFFFF_FF00;
        const base = own & mask;
        var host: u32 = 1;
        while (host < ~mask and n < out.len) : (host += 1) {
            const addr = base | host;
            if (addr == own) continue;
            out[n] = std.mem.nativeToBig(u32, addr);
            n += 1;
        }
        subnets += 1;
    }
    return out[0..n];
}

fn privateAddress(addr: u32) bool {
    const a: u8 = @truncate(addr >> 24);
    const b: u8 = @truncate(addr >> 16);
    return a == 10 or (a == 172 and b >= 16 and b < 32) or (a == 192 and b == 168);
}
