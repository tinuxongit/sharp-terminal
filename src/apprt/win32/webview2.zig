//! Microsoft's WebView2, the Edge engine Windows ships, through the COM
//! interfaces of its WebView2.h: only the calls the browser panel makes,
//! with the slots it skips left as placeholders so the order still
//! matches. WebView2Loader.dll loads from beside the exe, and only when a
//! browser panel first opens.
const std = @import("std");
const w32 = @import("win32.zig");

const HRESULT = w32.HRESULT;
const GUID = w32.GUID;
/// Win32 BOOL, as the raw int the vtables pass.
const BOOL = c_int;
/// A vtable slot the panel never calls.
const Unused = ?*const anyopaque;

pub const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const Token = extern struct { value: i64 };

fn Iunknown(comptime Self: type) type {
    return struct {
        pub fn release(self: *Self) void {
            _ = self.vtable.Release(self);
        }
    };
}

pub const Environment = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*Environment) callconv(.winapi) u32,
        CreateCoreWebView2Controller: *const fn (*Environment, w32.HWND, *anyopaque) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Environment).release;
};

pub const Controller = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*Controller) callconv(.winapi) u32,
        Release: *const fn (*Controller) callconv(.winapi) u32,
        get_IsVisible: Unused,
        put_IsVisible: *const fn (*Controller, BOOL) callconv(.winapi) HRESULT,
        get_Bounds: Unused,
        put_Bounds: *const fn (*Controller, w32.RECT) callconv(.winapi) HRESULT,
        _7: [5]Unused,
        MoveFocus: *const fn (*Controller, u32) callconv(.winapi) HRESULT,
        _13: [10]Unused,
        NotifyParentWindowPositionChanged: *const fn (*Controller) callconv(.winapi) HRESULT,
        Close: *const fn (*Controller) callconv(.winapi) HRESULT,
        get_CoreWebView2: *const fn (*Controller, *?*WebView) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Controller).release;
    pub const focus_programmatic: u32 = 0;
};

/// ICoreWebView2: one page and its history.
pub const WebView = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*WebView) callconv(.winapi) u32,
        get_Settings: Unused,
        get_Source: *const fn (*WebView, *?[*:0]u16) callconv(.winapi) HRESULT,
        Navigate: *const fn (*WebView, [*:0]const u16) callconv(.winapi) HRESULT,
        _6: [5]Unused,
        add_SourceChanged: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _12: Unused,
        add_HistoryChanged: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _14: [17]Unused,
        Reload: *const fn (*WebView) callconv(.winapi) HRESULT,
        _32: [4]Unused,
        /// Chrome DevTools Protocol, which Claude's tools read and drive the
        /// page through.
        CallDevToolsProtocolMethod: *const fn (*WebView, [*:0]const u16, [*:0]const u16, *anyopaque) callconv(.winapi) HRESULT,
        _37: Unused,
        get_CanGoBack: *const fn (*WebView, *BOOL) callconv(.winapi) HRESULT,
        get_CanGoForward: *const fn (*WebView, *BOOL) callconv(.winapi) HRESULT,
        GoBack: *const fn (*WebView) callconv(.winapi) HRESULT,
        GoForward: *const fn (*WebView) callconv(.winapi) HRESULT,
        GetDevToolsProtocolEventReceiver: *const fn (*WebView, [*:0]const u16, *?*EventReceiver) callconv(.winapi) HRESULT,
        _43: Unused,
        add_NewWindowRequested: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(WebView).release;
};

pub const EventReceiver = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*EventReceiver) callconv(.winapi) u32,
        add_DevToolsProtocolEventReceived: *const fn (*EventReceiver, *anyopaque, *Token) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(EventReceiver).release;
};

pub const EventArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        get_ParameterObjectAsJson: *const fn (*EventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
    },
};

pub const NewWindowArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        get_Uri: *const fn (*NewWindowArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        put_NewWindow: Unused,
        get_NewWindow: Unused,
        put_Handled: *const fn (*NewWindowArgs, BOOL) callconv(.winapi) HRESULT,
    },
};

fn iid(d1: u32, d2: u16, d3: u16, d4: [8]u8) GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

const iid_unknown = iid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });
pub const iid_environment_completed = iid(0x4e8a3389, 0xc9d8, 0x4bd2, .{ 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d });
pub const iid_controller_completed = iid(0x6c4819f3, 0xc9b7, 0x4260, .{ 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c });
pub const iid_source_changed = iid(0x3c067f9f, 0x5388, 0x4772, .{ 0x8b, 0x48, 0x79, 0xf7, 0xef, 0x1a, 0xb3, 0x7c });
pub const iid_history_changed = iid(0xc79a420c, 0xefd9, 0x4058, .{ 0x92, 0x95, 0x3e, 0x8b, 0x4b, 0xca, 0xb6, 0x45 });
pub const iid_new_window = iid(0xd4c185fe, 0xc81c, 0x4989, .{ 0x97, 0xaf, 0x2d, 0x3f, 0xa7, 0xab, 0x56, 0x51 });
pub const iid_cdp_completed = iid(0x5c4889f0, 0x5ef6, 0x4c5a, .{ 0x95, 0x2c, 0xd8, 0xf1, 0xb9, 0x2d, 0x05, 0x74 });
pub const iid_cdp_event = iid(0xe2fda4be, 0x5456, 0x406c, .{ 0xa2, 0x61, 0x3d, 0x45, 0x21, 0x38, 0x36, 0x2c });

/// A handler object WebView2 calls back, running `invoke(context, a, b)`.
/// WebView2 keeps a reference while it may still call, so the object
/// frees itself on its last Release. The panel's handlers carry its window
/// rather than the panel, so a callback arriving after the panel closed
/// finds no panel instead of a freed one.
pub fn Handler(comptime handler_iid: GUID, comptime A: type, comptime B: type, comptime invoke: fn (usize, A, B) void) type {
    return extern struct {
        const Self = @This();

        vtable: *const Vtbl = &vtbl,
        refs: std.atomic.Value(u32) = .init(1),
        context: usize,

        const Vtbl = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: *const fn (*Self, A, B) callconv(.winapi) HRESULT,
        };
        const vtbl: Vtbl = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .Invoke = call };

        /// The caller owns one reference and releases it once WebView2 has
        /// taken its own.
        pub fn create(context: usize) ?*Self {
            const self = std.heap.smp_allocator.create(Self) catch return null;
            self.* = .{ .context = context };
            return self;
        }

        fn queryInterface(self: *Self, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (std.meta.eql(riid.*, handler_iid) or std.meta.eql(riid.*, iid_unknown)) {
                _ = addRef(self);
                out.* = self;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        fn addRef(self: *Self) callconv(.winapi) u32 {
            return self.refs.fetchAdd(1, .monotonic) + 1;
        }

        pub fn release(self: *Self) callconv(.winapi) u32 {
            const left = self.refs.fetchSub(1, .acq_rel) - 1;
            if (left == 0) std.heap.smp_allocator.destroy(self);
            return left;
        }

        fn call(self: *Self, a: A, b: B) callconv(.winapi) HRESULT {
            invoke(self.context, a, b);
            return S_OK;
        }
    };
}

const CreateEnvironmentFn = *const fn (?[*:0]const u16, ?[*:0]const u16, ?*anyopaque, *anyopaque) callconv(.winapi) HRESULT;
var create_environment: ?CreateEnvironmentFn = null;

pub const Error = error{ LoaderMissing, NameTooLong, Failed };

/// Start creating an environment whose profile (cookies, logins, cache)
/// lives in `user_data`; `handler` receives it. Loads the loader the first
/// time, from beside the exe, so a planted copy elsewhere is never used.
pub fn createEnvironment(user_data: [*:0]const u16, handler: *anyopaque) Error!void {
    const create = create_environment orelse blk: {
        var path: [1024]u16 = undefined;
        const len = w32.GetModuleFileNameW(null, &path, path.len);
        if (len == 0 or len >= path.len) return error.NameTooLong;
        const dir_end = (std.mem.lastIndexOfScalar(u16, path[0..len], '\\') orelse return error.LoaderMissing) + 1;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");
        if (dir_end + name.len + 1 > path.len) return error.NameTooLong;
        @memcpy(path[dir_end..][0..name.len], name);
        path[dir_end + name.len] = 0;
        const module = w32.LoadLibraryExW(@ptrCast(&path), null, w32.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | w32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse
            return error.LoaderMissing;
        const proc = w32.GetProcAddress(module, "CreateCoreWebView2EnvironmentWithOptions") orelse return error.LoaderMissing;
        const f: CreateEnvironmentFn = @ptrCast(@alignCast(proc));
        create_environment = f;
        break :blk f;
    };
    if (create(null, user_data, null, handler) < 0) return error.Failed;
}
