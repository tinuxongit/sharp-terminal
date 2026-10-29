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
        pub fn addRef(self: *Self) void {
            _ = self.vtable.AddRef(self);
        }
        pub fn release(self: *Self) void {
            _ = self.vtable.Release(self);
        }
    };
}

pub const Environment = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Environment) callconv(.winapi) u32,
        Release: *const fn (*Environment) callconv(.winapi) u32,
        CreateCoreWebView2Controller: *const fn (*Environment, w32.HWND, *anyopaque) callconv(.winapi) HRESULT,
    },
    pub const addRef = Iunknown(Environment).addRef;
    pub const release = Iunknown(Environment).release;

    pub fn as15(self: *Environment) ?*Environment15 {
        var out: ?*anyopaque = null;
        if (self.vtable.QueryInterface(self, &iid_environment15, &out) < 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

pub const Environment15 = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*Environment15) callconv(.winapi) u32,
        _3: [26]Unused,
        CreateFindOptions: *const fn (*Environment15, *?*FindOptions) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Environment15).release;
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
        _13: [6]Unused,
        add_AcceleratorKeyPressed: *const fn (*Controller, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _20: [3]Unused,
        NotifyParentWindowPositionChanged: *const fn (*Controller) callconv(.winapi) HRESULT,
        Close: *const fn (*Controller) callconv(.winapi) HRESULT,
        get_CoreWebView2: *const fn (*Controller, *?*WebView) callconv(.winapi) HRESULT,
    },
    pub const addRef = Iunknown(Controller).addRef;
    pub const release = Iunknown(Controller).release;
    pub const focus_programmatic: u32 = 0;
};

/// ICoreWebView2: one page and its history.
pub const WebView = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*WebView, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Unused,
        Release: *const fn (*WebView) callconv(.winapi) u32,
        get_Settings: *const fn (*WebView, *?*Settings) callconv(.winapi) HRESULT,
        get_Source: *const fn (*WebView, *?[*:0]u16) callconv(.winapi) HRESULT,
        Navigate: *const fn (*WebView, [*:0]const u16) callconv(.winapi) HRESULT,
        _6: Unused,
        add_NavigationStarting: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _8: [3]Unused,
        add_SourceChanged: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _12: Unused,
        add_HistoryChanged: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _14: Unused,
        add_NavigationCompleted: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _16: [5]Unused,
        add_ScriptDialogOpening: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _22: [3]Unused,
        add_ProcessFailed: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _26: [5]Unused,
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
        Stop: *const fn (*WebView) callconv(.winapi) HRESULT,
        add_NewWindowRequested: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _45: Unused,
        add_DocumentTitleChanged: *const fn (*WebView, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _47: Unused,
        get_DocumentTitle: *const fn (*WebView, *?[*:0]u16) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(WebView).release;

    fn query(self: *WebView, comptime T: type, riid: *const GUID) ?*T {
        var out: ?*anyopaque = null;
        if (self.vtable.QueryInterface(self, riid, &out) < 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }

    pub fn as15(self: *WebView) ?*WebView15 {
        return self.query(WebView15, &iid_webview15);
    }

    pub fn as28(self: *WebView) ?*WebView28 {
        return self.query(WebView28, &iid_webview28);
    }
};

pub const WebView15 = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*WebView15) callconv(.winapi) u32,
        _3: [72]Unused,
        add_DownloadStarting: *const fn (*WebView15, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _76: [23]Unused,
        CallDevToolsProtocolMethodForSession: *const fn (*WebView15, [*:0]const u16, [*:0]const u16, [*:0]const u16, *anyopaque) callconv(.winapi) HRESULT,
        _100: [9]Unused,
        add_FaviconChanged: *const fn (*WebView15, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _110: [2]Unused,
        GetFavicon: *const fn (*WebView15, c_int, *anyopaque) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(WebView15).release;
    pub const favicon_png: c_int = 0;
};

pub const WebView28 = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*WebView28) callconv(.winapi) u32,
        _3: [132]Unused,
        get_Find: *const fn (*WebView28, *?*Find) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(WebView28).release;
};

pub const Find = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*Find) callconv(.winapi) u32,
        _3: [6]Unused,
        Start: *const fn (*Find, *FindOptions, *anyopaque) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Find).release;
};

pub const FindOptions = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*FindOptions) callconv(.winapi) u32,
        _3: Unused,
        put_FindTerm: *const fn (*FindOptions, [*:0]const u16) callconv(.winapi) HRESULT,
        _5: [3]Unused,
        put_ShouldHighlightAllMatches: *const fn (*FindOptions, BOOL) callconv(.winapi) HRESULT,
        _9: [3]Unused,
        put_SuppressDefaultFindDialog: *const fn (*FindOptions, BOOL) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(FindOptions).release;
};

pub const Settings = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*Settings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Unused,
        Release: *const fn (*Settings) callconv(.winapi) u32,
        _3: [3]Unused,
        put_IsWebMessageEnabled: *const fn (*Settings, BOOL) callconv(.winapi) HRESULT,
        _7: Unused,
        put_AreDefaultScriptDialogsEnabled: *const fn (*Settings, BOOL) callconv(.winapi) HRESULT,
        _9: [7]Unused,
        put_AreHostObjectsAllowed: *const fn (*Settings, BOOL) callconv(.winapi) HRESULT,
        _17: Unused,
        put_IsZoomControlEnabled: *const fn (*Settings, BOOL) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Settings).release;

    pub fn as4(self: *Settings) ?*Settings4 {
        var out: ?*anyopaque = null;
        if (self.vtable.QueryInterface(self, &iid_settings4, &out) < 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

pub const Settings4 = extern struct {
    vtable: *const extern struct {
        _0: [2]Unused,
        Release: *const fn (*Settings4) callconv(.winapi) u32,
        _3: [23]Unused,
        put_IsPasswordAutosaveEnabled: *const fn (*Settings4, BOOL) callconv(.winapi) HRESULT,
        _27: Unused,
        put_IsGeneralAutofillEnabled: *const fn (*Settings4, BOOL) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Settings4).release;
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
        QueryInterface: *const fn (*EventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Unused,
        Release: Unused,
        get_ParameterObjectAsJson: *const fn (*EventArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
    },

    pub fn sessionId(self: *EventArgs, out: []u8) []const u8 {
        var raw: ?*anyopaque = null;
        if (self.vtable.QueryInterface(self, &iid_cdp_event_args2, &raw) < 0) return out[0..0];
        const args2: *EventArgs2 = @ptrCast(@alignCast(raw orelse return out[0..0]));
        defer _ = args2.vtable.Release(args2);
        var id: ?[*:0]u16 = null;
        if (args2.vtable.get_SessionId(args2, &id) < 0) return out[0..0];
        defer w32.CoTaskMemFree(id);
        const text = std.mem.span(id orelse return out[0..0]);
        var n: usize = 0;
        for (text) |c| {
            if (c >= 0x80 or n == out.len) return out[0..0];
            out[n] = @intCast(c);
            n += 1;
        }
        return out[0..n];
    }
};

const EventArgs2 = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*EventArgs2) callconv(.winapi) u32,
        get_ParameterObjectAsJson: Unused,
        get_SessionId: *const fn (*EventArgs2, *?[*:0]u16) callconv(.winapi) HRESULT,
    },
};

pub const ScriptDialogArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*ScriptDialogArgs) callconv(.winapi) u32,
        Release: *const fn (*ScriptDialogArgs) callconv(.winapi) u32,
        get_Uri: Unused,
        get_Kind: *const fn (*ScriptDialogArgs, *c_int) callconv(.winapi) HRESULT,
        get_Message: *const fn (*ScriptDialogArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        Accept: *const fn (*ScriptDialogArgs) callconv(.winapi) HRESULT,
        get_DefaultText: *const fn (*ScriptDialogArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        get_ResultText: Unused,
        put_ResultText: *const fn (*ScriptDialogArgs, [*:0]const u16) callconv(.winapi) HRESULT,
        GetDeferral: *const fn (*ScriptDialogArgs, *?*Deferral) callconv(.winapi) HRESULT,
    },
    pub const addRef = Iunknown(ScriptDialogArgs).addRef;
    pub const release = Iunknown(ScriptDialogArgs).release;
};

pub const ProcessFailedArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        get_ProcessFailedKind: *const fn (*ProcessFailedArgs, *c_int) callconv(.winapi) HRESULT,
    },
    pub const browser_exited: c_int = 0;
    pub const render_exited: c_int = 1;
    pub const render_unresponsive: c_int = 2;
};

pub const DownloadStartingArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        get_DownloadOperation: *const fn (*DownloadStartingArgs, *?*Download) callconv(.winapi) HRESULT,
    },
};

pub const Download = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*Download) callconv(.winapi) u32,
        Release: *const fn (*Download) callconv(.winapi) u32,
        _3: [4]Unused,
        add_StateChanged: *const fn (*Download, *anyopaque, *Token) callconv(.winapi) HRESULT,
        _8: Unused,
        get_Uri: *const fn (*Download, *?[*:0]u16) callconv(.winapi) HRESULT,
        _10: [3]Unused,
        get_BytesReceived: *const fn (*Download, *i64) callconv(.winapi) HRESULT,
        _14: Unused,
        get_ResultFilePath: *const fn (*Download, *?[*:0]u16) callconv(.winapi) HRESULT,
        get_State: *const fn (*Download, *c_int) callconv(.winapi) HRESULT,
    },
    pub const addRef = Iunknown(Download).addRef;
    pub const release = Iunknown(Download).release;
    pub const in_progress: c_int = 0;
    pub const interrupted: c_int = 1;
    pub const completed: c_int = 2;
};

pub const Stream = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        Read: *const fn (*Stream, [*]u8, u32, ?*u32) callconv(.winapi) HRESULT,
        Write: Unused,
        Seek: *const fn (*Stream, i64, u32, ?*u64) callconv(.winapi) HRESULT,
    },
};

pub const NewWindowArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*NewWindowArgs) callconv(.winapi) u32,
        Release: *const fn (*NewWindowArgs) callconv(.winapi) u32,
        get_Uri: *const fn (*NewWindowArgs, *?[*:0]u16) callconv(.winapi) HRESULT,
        put_NewWindow: *const fn (*NewWindowArgs, *WebView) callconv(.winapi) HRESULT,
        get_NewWindow: Unused,
        put_Handled: *const fn (*NewWindowArgs, BOOL) callconv(.winapi) HRESULT,
        get_Handled: Unused,
        get_IsUserInitiated: Unused,
        GetDeferral: *const fn (*NewWindowArgs, *?*Deferral) callconv(.winapi) HRESULT,
    },
    pub const addRef = Iunknown(NewWindowArgs).addRef;
    pub const release = Iunknown(NewWindowArgs).release;
};

pub const Deferral = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*Deferral) callconv(.winapi) u32,
        Complete: *const fn (*Deferral) callconv(.winapi) HRESULT,
    },
    pub const release = Iunknown(Deferral).release;
};

pub const KeyArgs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: Unused,
        get_KeyEventKind: *const fn (*KeyArgs, *c_int) callconv(.winapi) HRESULT,
        get_VirtualKey: *const fn (*KeyArgs, *u32) callconv(.winapi) HRESULT,
        get_KeyEventLParam: Unused,
        get_PhysicalKeyStatus: Unused,
        get_Handled: Unused,
        put_Handled: *const fn (*KeyArgs, BOOL) callconv(.winapi) HRESULT,
    },
    pub const key_down: c_int = 0;
    pub const system_key_down: c_int = 2;
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
pub const iid_title_changed = iid(0xf5f2b923, 0x953e, 0x4042, .{ 0x9f, 0x95, 0xf3, 0xa1, 0x18, 0xe1, 0xaf, 0xd4 });
pub const iid_accelerator_key = iid(0xb29c7e28, 0xfa79, 0x41a8, .{ 0x8e, 0x44, 0x65, 0x81, 0x1c, 0x76, 0xdc, 0xb2 });
pub const iid_cdp_completed = iid(0x5c4889f0, 0x5ef6, 0x4c5a, .{ 0x95, 0x2c, 0xd8, 0xf1, 0xb9, 0x2d, 0x05, 0x74 });
pub const iid_cdp_event = iid(0xe2fda4be, 0x5456, 0x406c, .{ 0xa2, 0x61, 0x3d, 0x45, 0x21, 0x38, 0x36, 0x2c });
pub const iid_navigation_starting = iid(0x9adbe429, 0xf36d, 0x432b, .{ 0x9d, 0xdc, 0xf8, 0x88, 0x1f, 0xbd, 0x76, 0xe3 });
pub const iid_navigation_completed = iid(0xd33a35bf, 0x1c49, 0x4f98, .{ 0x93, 0xab, 0x00, 0x6e, 0x05, 0x33, 0xfe, 0x1c });
pub const iid_script_dialog = iid(0xef381bf9, 0xafa8, 0x4e37, .{ 0x91, 0xc4, 0x8a, 0xc4, 0x85, 0x24, 0xbd, 0xfb });
pub const iid_process_failed = iid(0x79e0aea4, 0x990b, 0x42d9, .{ 0xaa, 0x1d, 0x0f, 0xcc, 0x2e, 0x5b, 0xc7, 0xf1 });
pub const iid_download_starting = iid(0xefedc989, 0xc396, 0x41ca, .{ 0x83, 0xf7, 0x07, 0xf8, 0x45, 0xa5, 0x57, 0x24 });
pub const iid_download_state = iid(0x81336594, 0x7ede, 0x4ba9, .{ 0xbf, 0x71, 0xac, 0xf0, 0xa9, 0x5b, 0x58, 0xdd });
pub const iid_favicon_changed = iid(0x2913da94, 0x833d, 0x4de0, .{ 0x8d, 0xca, 0x90, 0x0f, 0xc5, 0x24, 0xa1, 0xa4 });
pub const iid_favicon_completed = iid(0xa2508329, 0x7da8, 0x49d7, .{ 0x8c, 0x05, 0xfa, 0x12, 0x5e, 0x4a, 0xee, 0x8d });
pub const iid_find_started = iid(0x6a90ecaf, 0x44b0, 0x5bd9, .{ 0x8f, 0x07, 0x19, 0x67, 0xe1, 0x7b, 0xe9, 0xfb });
const iid_webview15 = iid(0x517b2d1d, 0x7dae, 0x4a66, .{ 0xa4, 0xf4, 0x10, 0x35, 0x2f, 0xfb, 0x95, 0x18 });
const iid_webview28 = iid(0x62e50381, 0x5bf5, 0x51a8, .{ 0xaa, 0xe0, 0xf2, 0x0a, 0x3a, 0x9c, 0x8a, 0x90 });
const iid_settings4 = iid(0xcb56846c, 0x4168, 0x4d53, .{ 0xb0, 0x4f, 0x03, 0xb6, 0xd6, 0x79, 0x6f, 0xf2 });
const iid_environment15 = iid(0x2ac5ebfb, 0xe654, 0x5961, .{ 0xa6, 0x67, 0x79, 0x71, 0x88, 0x5c, 0x7b, 0x27 });
const iid_cdp_event_args2 = iid(0x2dc4959d, 0x1494, 0x4393, .{ 0x95, 0xba, 0xbe, 0xa4, 0xcb, 0x9e, 0xbd, 0x1b });

/// A handler object WebView2 calls back, running `invoke(context, a, b)`.
/// WebView2 keeps a reference while it may still call, so the object
/// frees itself on its last Release. The panel's handlers carry its window
/// and a tab id rather than pointers, so a callback arriving after the
/// panel or tab closed finds nothing instead of freed memory.
pub fn Handler(comptime handler_iid: GUID, comptime Context: type, comptime A: type, comptime B: type, comptime invoke: fn (Context, A, B) void) type {
    return extern struct {
        const Self = @This();

        vtable: *const Vtbl = &vtbl,
        refs: std.atomic.Value(u32) = .init(1),
        context: Context,

        const Vtbl = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: *const fn (*Self, A, B) callconv(.winapi) HRESULT,
        };
        const vtbl: Vtbl = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .Invoke = call };

        /// The caller owns one reference and releases it once WebView2 has
        /// taken its own.
        pub fn create(context: Context) ?*Self {
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
