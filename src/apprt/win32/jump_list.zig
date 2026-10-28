//! The taskbar's jump list (right-click on Sharp's button): the installed
//! shell profiles, each opening as a tab in the running Sharp
//! (`sharp +new-tab --command=...`), as Windows Terminal lists its
//! profiles there. Built once at startup on a thread of its own.
const std = @import("std");
const w32 = @import("win32.zig");
const profiles = @import("profiles.zig");
const wide_string = @import("wide_string.zig");
const command_line = @import("command_line.zig");

const log = std.log.scoped(.jump_list);
const GUID = w32.GUID;
const HRESULT = w32.HRESULT;

pub fn update() void {
    const thread = std.Thread.spawn(.{}, build, .{}) catch |err| {
        log.warn("could not build the jump list: {}", .{err});
        return;
    };
    thread.detach();
}

fn build() void {
    if (w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED) < 0) return;
    defer w32.CoUninitialize();

    var exe: [1024:0]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return;
    exe[exe_len] = 0;

    var list: *DestinationList = undefined;
    if (w32.CoCreateInstance(&clsid_destination_list, null, w32.CLSCTX_INPROC_SERVER, &iid_custom_destination_list, @ptrCast(&list)) < 0) return;
    defer _ = list.vtbl.Release(list);
    var min_slots: u32 = 0;
    var removed: ?*anyopaque = null;
    if (list.vtbl.BeginList(list, &min_slots, &iid_object_array, &removed) < 0) return;
    if (removed) |r| _ = @as(*Unknown, @ptrCast(@alignCast(r))).vtbl.Release(@ptrCast(@alignCast(r)));

    var tasks: *ObjectCollection = undefined;
    if (w32.CoCreateInstance(&clsid_object_collection, null, w32.CLSCTX_INPROC_SERVER, &iid_object_collection, @ptrCast(&tasks)) < 0) {
        _ = list.vtbl.AbortList(list);
        return;
    }
    defer _ = tasks.vtbl.Release(tasks);

    const shells = profiles.detect();
    for (0..shells.len) |i| addProfile(tasks, &exe, shells.name(i), shells.command(i), shells.icon(i));

    if (list.vtbl.AddUserTasks(list, tasks) < 0 or list.vtbl.CommitList(list) < 0) {
        _ = list.vtbl.AbortList(list);
        log.warn("Windows refused the jump list", .{});
    }
}

/// A task that opens profile `name` (`command`) as a tab, with the icon
/// of `icon_program`.
fn addProfile(tasks: *ObjectCollection, exe: [*:0]const u16, name: []const u8, command: []const u8, icon_program: []const u8) void {
    var link: *ShellLink = undefined;
    if (w32.CoCreateInstance(&clsid_shell_link, null, w32.CLSCTX_INPROC_SERVER, &iid_shell_link, @ptrCast(&link)) < 0) return;
    defer _ = link.vtbl.Release(link);

    // `+new-tab "--command=<command>"`, quoted as Windows splits arguments.
    var args: [1200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&args);
    w.writeAll("+new-tab ") catch return;
    command_line.quote(&w, "--command=", command) catch return;
    var args_w: [1200:0]u16 = undefined;
    args_w[wide_string.fromUtf8(&args_w, w.buffered())] = 0;

    _ = link.vtbl.SetPath(link, exe);
    _ = link.vtbl.SetArguments(link, &args_w);
    var icon: [1024:0]u16 = undefined;
    if (programPath(icon_program, &icon)) |path| _ = link.vtbl.SetIconLocation(link, path, 0);

    // A task's title is the link's PKEY_Title.
    var store: *PropertyStore = undefined;
    if (link.vtbl.QueryInterface(link, &iid_property_store, @ptrCast(&store)) < 0) return;
    defer _ = store.vtbl.Release(store);
    var title: [128:0]u16 = undefined;
    title[wide_string.fromUtf8(&title, name)] = 0;
    var value: PropVariant = .{ .vt = vt_lpwstr, .value = @intFromPtr(&title) };
    if (store.vtbl.SetValue(store, &pkey_title, &value) < 0 or store.vtbl.Commit(store) < 0) return;
    _ = tasks.vtbl.AddObject(tasks, @ptrCast(link));
}

/// The full path of a program named on PATH or given whole.
fn programPath(program: []const u8, out: *[1024:0]u16) ?[*:0]const u16 {
    if (std.fs.path.isAbsolute(program)) {
        out[wide_string.fromUtf8(out, program)] = 0;
        return out;
    }
    var name: [260:0]u16 = undefined;
    name[wide_string.fromUtf8(&name, program)] = 0;
    const n = w32.SearchPathW(null, &name, null, out.len, out, null);
    if (n == 0 or n >= out.len) return null;
    return out;
}

const vt_lpwstr: u16 = 31;
const PropVariant = extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    value: usize,
    pad: usize = 0,
};
const PropertyKey = extern struct { fmtid: GUID, pid: u32 };
const pkey_title: PropertyKey = .{ .fmtid = guid(0xF29F85E0, 0x4FF9, 0x1068, .{ 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9 }), .pid = 2 };

const clsid_destination_list = guid(0x77f10cf0, 0x3db5, 0x4966, .{ 0xb5, 0x20, 0xb7, 0xc5, 0x4f, 0xd3, 0x5e, 0xd6 });
const iid_custom_destination_list = guid(0x6332debf, 0x87b5, 0x4670, .{ 0x90, 0xc0, 0x5e, 0x57, 0xb4, 0x08, 0xa4, 0x9e });
const iid_object_array = guid(0x92ca9dcd, 0x5622, 0x4bba, .{ 0xa8, 0x05, 0x5e, 0x9f, 0x54, 0x1b, 0xd8, 0xc9 });
const clsid_object_collection = guid(0x2d3468c1, 0x36a7, 0x43b6, .{ 0xac, 0x24, 0xd3, 0xf0, 0x2f, 0xd9, 0x60, 0x7a });
const iid_object_collection = guid(0x5632b1a4, 0xe38a, 0x400a, .{ 0x92, 0x8a, 0xd4, 0xcd, 0x63, 0x23, 0x02, 0x95 });
const clsid_shell_link = guid(0x00021401, 0x0000, 0x0000, .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_shell_link = guid(0x000214F9, 0x0000, 0x0000, .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_property_store = guid(0x886d8eeb, 0x8cf2, 0x4446, .{ 0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99 });

fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

const Unknown = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*Unknown) callconv(.winapi) u32,
    },
};

const DestinationList = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*DestinationList) callconv(.winapi) u32,
        SetAppID: *const anyopaque,
        BeginList: *const fn (*DestinationList, *u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AppendCategory: *const anyopaque,
        AppendKnownCategory: *const anyopaque,
        AddUserTasks: *const fn (*DestinationList, *ObjectCollection) callconv(.winapi) HRESULT,
        CommitList: *const fn (*DestinationList) callconv(.winapi) HRESULT,
        GetRemovedDestinations: *const anyopaque,
        DeleteList: *const anyopaque,
        AbortList: *const fn (*DestinationList) callconv(.winapi) HRESULT,
    },
};

const ObjectCollection = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ObjectCollection) callconv(.winapi) u32,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        AddObject: *const fn (*ObjectCollection, *anyopaque) callconv(.winapi) HRESULT,
        AddFromArray: *const anyopaque,
        RemoveObjectAt: *const anyopaque,
        Clear: *const anyopaque,
    },
};

const ShellLink = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*ShellLink, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (*ShellLink) callconv(.winapi) u32,
        GetPath: *const anyopaque,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const anyopaque,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const anyopaque,
        GetArguments: *const anyopaque,
        SetArguments: *const fn (*ShellLink, [*:0]const u16) callconv(.winapi) HRESULT,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*ShellLink, [*:0]const u16, i32) callconv(.winapi) HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*ShellLink, [*:0]const u16) callconv(.winapi) HRESULT,
    },
};

const PropertyStore = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*PropertyStore) callconv(.winapi) u32,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const anyopaque,
        SetValue: *const fn (*PropertyStore, *const PropertyKey, *const PropVariant) callconv(.winapi) HRESULT,
        Commit: *const fn (*PropertyStore) callconv(.winapi) HRESULT,
    },
};
