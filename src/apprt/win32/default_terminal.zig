//! Makes Sharp Windows' default terminal and gives the choice back, for
//! Settings > General > Default terminal (`default-terminal`). Windows
//! keeps the choice as two class ids in HKCU\Console\%%Startup, the values
//! its own setting (System > For developers > Terminal) writes; it lists
//! only packaged terminals, so Sharp writes them itself. Windows
//! Terminal's console stays the console host and hands each console on to
//! Sharp (terminal_handoff.zig). Whatever was chosen before is kept under
//! HKCU\Software\Sharp and put back when the switch, or the uninstaller
//! (dist/windows/installer.nsi), gives the choice back.
const std = @import("std");
const w32 = @import("win32.zig");
const terminal_handoff = @import("terminal_handoff.zig");

const log = std.log.scoped(.default_terminal);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const startup_key = L("Console\\%%Startup");
const saved_key = L("Software\\Sharp\\DefaultTerminal");
const values = [_][:0]const u16{ L("DelegationConsole"), L("DelegationTerminal") };

const class_key = L("Software\\Classes\\CLSID\\" ++ terminal_handoff.class_id);
const interface_key = L("Software\\Classes\\Interface\\" ++ terminal_handoff.interface_id);
const proxy_key = L("Software\\Classes\\CLSID\\" ++ terminal_handoff.proxy_id);

/// A class id as the registry holds it, "{...}".
const Id = struct {
    buf: [40]u16 = undefined,
    len: usize = 0,

    fn slice(self: *const Id) []const u16 {
        return self.buf[0..self.len];
    }

    fn eql(self: *const Id, text: []const u8) bool {
        if (self.len != text.len) return false;
        for (self.slice(), text) |a, b| {
            if (a > 0x7f or std.ascii.toLower(@intCast(a)) != std.ascii.toLower(b)) return false;
        }
        return true;
    }
};

/// Point Windows at Sharp, remembering what it pointed at.
pub fn claim() !void {
    try registerClasses();
    const current = [_]?Id{ read(startup_key, values[0]), read(startup_key, values[1]) };
    const ours = if (current[1]) |id| id.eql(terminal_handoff.class_id) else false;
    if (!ours) {
        _ = w32.RegDeleteTreeW(w32.HKEY_CURRENT_USER, saved_key);
        const saved = try create(saved_key);
        defer _ = w32.RegCloseKey(saved);
        for (values, current) |name, value| if (value) |v| try set(saved, name, v.slice());
    }
    const startup = try create(startup_key);
    defer _ = w32.RegCloseKey(startup);
    try set(startup, values[0], L(terminal_handoff.windows_terminal_console_id));
    try set(startup, values[1], L(terminal_handoff.class_id));
}

/// Give Windows back what it pointed at before, unless someone has
/// chosen another terminal since.
pub fn release() void {
    const current = read(startup_key, values[1]);
    if (current != null and current.?.eql(terminal_handoff.class_id)) restore: {
        const startup = create(startup_key) catch break :restore;
        defer _ = w32.RegCloseKey(startup);
        for (values) |name| {
            if (read(saved_key, name)) |before| {
                set(startup, name, before.slice()) catch |err| log.warn("could not restore the default terminal: {}", .{err});
            } else _ = w32.RegDeleteValueW(startup, name);
        }
    }
    _ = w32.RegDeleteTreeW(w32.HKEY_CURRENT_USER, saved_key);
    for ([_][:0]const u16{ class_key, interface_key, proxy_key }) |key|
        _ = w32.RegDeleteTreeW(w32.HKEY_CURRENT_USER, key);
}

/// Keep the registrations pointing at this copy of Sharp, wherever it is.
pub fn refresh() void {
    registerClasses() catch |err| log.warn("could not register Sharp as a terminal: {}", .{err});
}

/// Where Windows starts Sharp for a console when it isn't running, and
/// the marshaling code Sharp needs to be called at all, from Sharp's own
/// folder: Windows won't load Windows Terminal's copy into another app.
fn registerClasses() !void {
    var exe: [1024]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return error.NoExePath;
    const dir_len = (std.mem.lastIndexOfScalar(u16, exe[0..exe_len], '\\') orelse return error.NoExePath) + 1;

    var proxy: [1100:0]u16 = undefined;
    const proxy_name = L("OpenConsoleProxy.dll");
    if (dir_len + proxy_name.len >= proxy.len) return error.NameTooLong;
    @memcpy(proxy[0..dir_len], exe[0..dir_len]);
    @memcpy(proxy[dir_len..][0..proxy_name.len], proxy_name);
    proxy[dir_len + proxy_name.len] = 0;
    if (w32.GetFileAttributesW(&proxy) == 0xFFFFFFFF) return error.ProxyMissing;

    var server: [1100]u16 = undefined;
    server[0] = '"';
    @memcpy(server[1..][0..exe_len], exe[0..exe_len]);
    server[exe_len + 1] = '"';

    try setKey(L("Software\\Classes\\CLSID\\" ++ terminal_handoff.class_id ++ "\\LocalServer32"), null, server[0 .. exe_len + 2]);
    try setKey(L("Software\\Classes\\Interface\\" ++ terminal_handoff.interface_id ++ "\\ProxyStubClsid32"), null, L(terminal_handoff.proxy_id));
    const inproc = L("Software\\Classes\\CLSID\\" ++ terminal_handoff.proxy_id ++ "\\InprocServer32");
    try setKey(inproc, null, proxy[0 .. dir_len + proxy_name.len]);
    try setKey(inproc, L("ThreadingModel"), L("Both"));
}

fn setKey(path: [:0]const u16, name: ?[:0]const u16, text: []const u16) !void {
    const key = try create(path);
    defer _ = w32.RegCloseKey(key);
    try set(key, name, text);
}

fn create(path: [:0]const u16) !w32.HKEY {
    var key: w32.HKEY = undefined;
    if (w32.RegCreateKeyExW(w32.HKEY_CURRENT_USER, path, 0, null, 0, w32.KEY_READ | w32.KEY_SET_VALUE, null, &key, null) != w32.ERROR_SUCCESS)
        return error.RegistryWriteFailed;
    return key;
}

fn set(key: w32.HKEY, name: ?[:0]const u16, text: []const u16) !void {
    var buf: [1100]u16 = undefined;
    if (text.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const bytes = std.mem.sliceAsBytes(buf[0 .. text.len + 1]);
    if (w32.RegSetValueExW(key, if (name) |n| n.ptr else null, 0, w32.REG_SZ, bytes.ptr, @intCast(bytes.len)) != w32.ERROR_SUCCESS)
        return error.RegistryWriteFailed;
}

fn read(path: [:0]const u16, name: [:0]const u16) ?Id {
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, path, 0, w32.KEY_READ, &key) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(key);
    var id: Id = .{};
    var kind: u32 = 0;
    var size: u32 = @sizeOf(@TypeOf(id.buf));
    if (w32.RegQueryValueExW(key, name, null, &kind, std.mem.sliceAsBytes(&id.buf).ptr, &size) != w32.ERROR_SUCCESS or kind != w32.REG_SZ)
        return null;
    id.len = std.mem.indexOfScalar(u16, id.buf[0 .. size / 2], 0) orelse size / 2;
    return id;
}
