//! Sharp's side of being Windows' default terminal (default_terminal.zig):
//! a COM class that Windows Terminal's console calls to hand over a
//! console started outside Sharp, through ITerminalHandoff3 from Windows
//! Terminal's src/host/proxy/ITerminalHandoff.idl. Calls arrive on COM's
//! threads; the console waits in os/console_handoff.zig and the app opens
//! it in a tab (App.openHandedOver). Registered while the switch is on,
//! and whenever Windows started Sharp for a console (-Embedding).
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const wide_string = @import("wide_string.zig");

const console_handoff = internal_os.console_handoff;
const windows = internal_os.windows;
const log = std.log.scoped(.terminal_handoff);
const GUID = w32.GUID;
const HANDLE = windows.HANDLE;
const HRESULT = w32.HRESULT;

/// Sharp's terminal class, which Windows' choice of terminal names.
pub const class_id = "{88076DA1-582B-4D00-BB74-1CAB70E0738E}";
/// ITerminalHandoff3.
pub const interface_id = "{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}";
/// The marshaling code for it, OpenConsoleProxy.dll.
pub const proxy_id = "{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}";
/// Windows Terminal's console, which stays the console host.
pub const windows_terminal_console_id = "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}";

const class = guid(class_id);
const iid_handoff3 = guid(interface_id);
const iid_unknown = guid("{00000000-0000-0000-C000-000000000046}");
const iid_class_factory = guid("{00000001-0000-0000-C000-000000000046}");

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));

/// TERMINAL_STARTUP_INFO; only the fields Sharp reads are named for use.
const StartupInfo = extern struct {
    title: ?[*:0]const u16,
    icon_path: ?[*:0]const u16,
    icon_index: i32,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_count_chars: u32,
    y_count_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
};

/// A console waiting for its tab, as the app learns of it.
pub const Handed = struct {
    id: u32,
    program_buf: [520]u8 = undefined,
    program_len: usize = 0,

    /// The full path of the program the console was made for.
    pub fn program(self: *const Handed) []const u8 {
        return self.program_buf[0..self.program_len];
    }

    /// Its file name, as the tab's profile name.
    pub fn name(self: *const Handed) []const u8 {
        const path = self.program();
        const slash = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return path;
        return path[slash + 1 ..];
    }
};

var lock: std.Io.Mutex = .init;
var queue: [8]Handed = undefined;
var queue_len: usize = 0;
var notify: ?w32.HWND = null;
var notify_message: u32 = 0;
var stop_event: ?w32.HANDLE = null;

/// Take calls for Sharp's class; `message` is posted to `hwnd` when a
/// console arrives.
pub fn start(hwnd: w32.HWND, message: u32) void {
    if (stop_event != null) return;
    notify = hwnd;
    notify_message = message;
    const event = w32.CreateEventW(null, 1, 0, null) orelse return;
    const thread = std.Thread.spawn(.{}, serve, .{event}) catch |err| {
        log.warn("failed to start the terminal handoff: {}", .{err});
        _ = w32.CloseHandle(event);
        return;
    };
    thread.detach();
    stop_event = event;
}

pub fn stop() void {
    const event = stop_event orelse return;
    stop_event = null;
    _ = w32.SetEvent(event);
}

/// The next console that arrived, oldest first.
pub fn next() ?Handed {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    if (queue_len == 0) return null;
    const first = queue[0];
    std.mem.copyForwards(Handed, queue[0 .. queue_len - 1], queue[1..queue_len]);
    queue_len -= 1;
    return first;
}

/// Whether Windows started Sharp to take a console: COM adds -Embedding
/// to the command line it registered (default_terminal.zig).
pub fn launchedByWindows() bool {
    const line = std.mem.span(w32.GetCommandLineW());
    const flag = std.unicode.utf8ToUtf16LeStringLiteral(" -Embedding");
    return std.mem.endsWith(u16, std.mem.trimEnd(u16, line, &.{' '}), flag);
}

/// The class lives in the multithreaded apartment, so calls run on COM's
/// threads and never wait for the UI.
fn serve(event: w32.HANDLE) void {
    defer _ = w32.CloseHandle(event);
    _ = w32.CoInitializeEx(null, w32.COINIT_MULTITHREADED);
    defer w32.CoUninitialize();
    var cookie: u32 = 0;
    const hr = w32.CoRegisterClassObject(&class, &factory, w32.CLSCTX_LOCAL_SERVER, w32.REGCLS_MULTIPLEUSE, &cookie);
    if (hr < 0) {
        log.warn("registering the terminal class failed hresult=0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }
    _ = w32.WaitForSingleObject(event, w32.INFINITE);
    _ = w32.CoRevokeClassObject(cookie);
}

fn establish(
    _: *Handoff,
    in: *HANDLE,
    out: *HANDLE,
    signal: HANDLE,
    reference: HANDLE,
    server: HANDLE,
    client: HANDLE,
    _: ?*const StartupInfo,
) callconv(.winapi) HRESULT {
    var handed: Handed = .{ .id = 0 };
    var wide: [260:0]u16 = undefined;
    var wide_len: windows.DWORD = wide.len;
    if (windows.exp.kernel32.QueryFullProcessImageNameW(client, 0, &wide, &wide_len) != windows.FALSE)
        handed.program_len = wide_string.toUtf8(&handed.program_buf, wide[0..wide_len]);

    const arrival = console_handoff.arrive(server, reference, signal, client) catch |err| {
        log.warn("could not take a handed-over console: {}", .{err});
        return E_FAIL;
    };
    handed.id = arrival.id;
    queued: {
        lock.lockUncancelable(global.io());
        defer lock.unlock(global.io());
        if (queue_len == queue.len) break :queued;
        queue[queue_len] = handed;
        queue_len += 1;
        in.* = arrival.input;
        out.* = arrival.output;
        if (notify) |hwnd| _ = w32.PostMessageW(hwnd, notify_message, 0, 0);
        return S_OK;
    }
    _ = w32.CloseHandle(arrival.input);
    _ = w32.CloseHandle(arrival.output);
    console_handoff.discard(arrival.id);
    return E_FAIL;
}

/// One object serves every call; COM holds no state in it.
const Handoff = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*Handoff, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Handoff) callconv(.winapi) u32,
        Release: *const fn (*Handoff) callconv(.winapi) u32,
        EstablishPtyHandoff: *const @TypeOf(establish),
    },

    fn queryInterface(self: *Handoff, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (eql(riid, iid_unknown) or eql(riid, iid_handoff3)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }
};

const Factory = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*Factory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Factory) callconv(.winapi) u32,
        Release: *const fn (*Factory) callconv(.winapi) u32,
        CreateInstance: *const fn (*Factory, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        LockServer: *const fn (*Factory, i32) callconv(.winapi) HRESULT,
    },

    fn queryInterface(self: *Factory, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (eql(riid, iid_unknown) or eql(riid, iid_class_factory)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn createInstance(_: *Factory, outer: ?*anyopaque, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (outer != null) return CLASS_E_NOAGGREGATION;
        return Handoff.queryInterface(&handoff, riid, out);
    }

    fn lockServer(_: *Factory, _: i32) callconv(.winapi) HRESULT {
        return S_OK;
    }
};

/// Static objects: their counts don't matter.
fn addRef(_: *anyopaque) callconv(.winapi) u32 {
    return 1;
}

var handoff: Handoff = .{ .vtbl = &.{
    .QueryInterface = Handoff.queryInterface,
    .AddRef = @ptrCast(&addRef),
    .Release = @ptrCast(&addRef),
    .EstablishPtyHandoff = establish,
} };

var factory: Factory = .{ .vtbl = &.{
    .QueryInterface = Factory.queryInterface,
    .AddRef = @ptrCast(&addRef),
    .Release = @ptrCast(&addRef),
    .CreateInstance = Factory.createInstance,
    .LockServer = Factory.lockServer,
} };

fn eql(a: *const GUID, b: GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(&b));
}

/// "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" as a GUID, at compile time.
fn guid(comptime text: []const u8) GUID {
    const hex = struct {
        fn n(comptime T: type, comptime s: []const u8) T {
            return std.fmt.parseInt(T, s, 16) catch @compileError("bad GUID " ++ text);
        }
    };
    if (text.len != 38) @compileError("bad GUID " ++ text);
    return .{
        .Data1 = hex.n(u32, text[1..9]),
        .Data2 = hex.n(u16, text[10..14]),
        .Data3 = hex.n(u16, text[15..19]),
        .Data4 = .{
            hex.n(u8, text[20..22]), hex.n(u8, text[22..24]),
            hex.n(u8, text[25..27]), hex.n(u8, text[27..29]),
            hex.n(u8, text[29..31]), hex.n(u8, text[31..33]),
            hex.n(u8, text[33..35]), hex.n(u8, text[35..37]),
        },
    };
}
