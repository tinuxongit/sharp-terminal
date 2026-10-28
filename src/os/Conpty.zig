//! Keep each pseudoconsole on one backend for its entire lifetime. Packaged
//! builds use the current Microsoft redistributable beside ghostty.exe;
//! standalone test executables can fall back to the Windows inbox backend.
const Conpty = @This();

const std = @import("std");
const windows = @import("windows.zig");

const log = std.log.scoped(.conpty);
const HMODULE = std.os.windows.HMODULE;
const Create = *const @TypeOf(windows.exp.kernel32.CreatePseudoConsole);
const Resize = *const @TypeOf(windows.exp.kernel32.ResizePseudoConsole);
const Close = *const @TypeOf(windows.exp.kernel32.ClosePseudoConsole);
/// Wraps a console handed over by another console host (Pty.adopt).
const Pack = *const fn (server: windows.HANDLE, reference: windows.HANDLE, signal: windows.HANDLE, pseudo_console: *windows.HPCON) callconv(.winapi) windows.HRESULT;

module: ?HMODULE = null,
create: Create = &windows.exp.kernel32.CreatePseudoConsole,
resize: Resize = &windows.exp.kernel32.ResizePseudoConsole,
close: Close = &windows.exp.kernel32.ClosePseudoConsole,
/// Only the bundled redistributable has it; Windows' inbox ConPTY doesn't.
pack: ?Pack = null,

pub const Error = error{
    Unexpected,
    NameTooLong,
    ConptyLoadFailed,
    ConptyMissingExport,
    ConptyHostMissing,
};

pub fn init() Error!Conpty {
    var path_buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (exe_len == 0) return windows.unexpectedError(windows.GetLastError());
    if (exe_len >= path_buf.len) return error.NameTooLong;
    var path = try siblingPath(&path_buf, exe_len, std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"));

    // Only absence of the bundled DLL permits a fallback. A present DLL with
    // a missing dependency, invalid image, or inaccessible path must fail.
    if (GetFileAttributesW(path.ptr) == 0xFFFFFFFF) {
        const err = windows.GetLastError();
        switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => return .{},
            else => return windows.unexpectedError(err),
        }
    }

    // The redistributable itself can silently launch the inbox conhost when
    // its matching OpenConsole.exe is missing. Reject a partial package so
    // that it cannot bring back the old console's reply/echo loop.
    path = try siblingPath(&path_buf, path.len, std.unicode.utf8ToUtf16LeStringLiteral("OpenConsole.exe"));
    const host_attributes = GetFileAttributesW(path.ptr);
    if (host_attributes == 0xFFFFFFFF) {
        log.err("bundled conpty.dll requires sibling OpenConsole.exe err={}", .{windows.GetLastError()});
        return error.ConptyHostMissing;
    }
    if (host_attributes & 0x10 != 0) {
        log.err("bundled OpenConsole.exe is a directory", .{});
        return error.ConptyHostMissing;
    }
    path = try siblingPath(&path_buf, path.len, std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"));

    // An absolute filename and these flags exclude the working directory and
    // PATH, including when loading dependencies of the redistributable DLL.
    const module = LoadLibraryExW(path.ptr, null, 0x00000100 | 0x00000800) orelse {
        log.err("loading bundled conpty.dll failed err={}", .{windows.GetLastError()});
        return error.ConptyLoadFailed;
    };
    errdefer _ = FreeLibrary(module);

    return .{
        .module = module,
        .create = try resolve(module, Create, "ConptyCreatePseudoConsole"),
        .resize = try resolve(module, Resize, "ConptyResizePseudoConsole"),
        .close = try resolve(module, Close, "ConptyClosePseudoConsole"),
        .pack = try resolve(module, Pack, "ConptyPackPseudoConsole"),
    };
}

pub fn deinit(self: *Conpty) void {
    if (self.module) |module| _ = FreeLibrary(module);
    self.* = undefined;
}

fn resolve(module: HMODULE, comptime T: type, name: [:0]const u8) Error!T {
    const address = GetProcAddress(module, name.ptr) orelse {
        log.err("bundled conpty.dll is missing export {s} err={}", .{ name, windows.GetLastError() });
        return error.ConptyMissingExport;
    };
    return @ptrCast(@alignCast(address));
}

/// Replace the filename in an absolute executable path without allocating or
/// converting away from the original Windows UTF-16 representation.
fn siblingPath(buf: []u16, exe_len: usize, name: []const u16) Error![:0]const u16 {
    var dir_len = exe_len;
    while (dir_len > 0 and buf[dir_len - 1] != '\\' and buf[dir_len - 1] != '/') : (dir_len -= 1) {}
    if (dir_len == 0) return error.Unexpected;
    if (name.len >= buf.len - dir_len) return error.NameTooLong;
    @memcpy(buf[dir_len..][0..name.len], name);
    const len = dir_len + name.len;
    buf[len] = 0;
    return buf[0..len :0];
}

extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, filename: [*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetFileAttributesW(filename: [*:0]const u16) callconv(.winapi) windows.DWORD;
extern "kernel32" fn LoadLibraryExW(filename: [*:0]const u16, file: ?windows.HANDLE, flags: windows.DWORD) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) windows.BOOL;

test "Conpty sibling path stays beside executable" {
    const testing = std.testing;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll");
    const cases = .{
        .{ "C:\\Program Files\\Ghostty\\ghostty.exe", "C:\\Program Files\\Ghostty\\conpty.dll" },
        .{ "C:/Ghostty/ghostty.exe", "C:/Ghostty/conpty.dll" },
        .{ "\\\\server\\share\\ghostty.exe", "\\\\server\\share\\conpty.dll" },
    };
    inline for (cases) |case| {
        var buf: [128]u16 = undefined;
        const exe = std.unicode.utf8ToUtf16LeStringLiteral(case[0]);
        @memcpy(buf[0..exe.len], exe);
        const path = try siblingPath(&buf, exe.len, name);
        try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(case[1]), path);
        try testing.expectEqual(@as(u16, 0), path.ptr[path.len]);
    }
}

test "Conpty sibling path rejects missing directory and truncation" {
    const testing = std.testing;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll");
    var buf: [16]u16 = undefined;
    const relative = std.unicode.utf8ToUtf16LeStringLiteral("ghostty.exe");
    @memcpy(buf[0..relative.len], relative);
    try testing.expectError(error.Unexpected, siblingPath(&buf, relative.len, name));

    const absolute = std.unicode.utf8ToUtf16LeStringLiteral("C:\\bin\\g.exe");
    @memcpy(buf[0..absolute.len], absolute);
    try testing.expectError(error.NameTooLong, siblingPath(&buf, absolute.len, name));
}
