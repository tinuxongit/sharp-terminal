//! The named pipe between Sharp's MCP server and the sharp-mcp bridge that
//! Claude Code starts. Its name carries the Windows user, only that user
//! may open it, and the bridge checks the pipe's server runs as that user
//! too, so another account can neither reach Sharp nor pose as it.
const std = @import("std");
const w32 = @import("win32.zig");

pub const Name = [300:0]u16;

/// \\.\pipe\Sharp-MCP-<user>, or null when Windows won't say the user.
pub fn name(out: *Name) ?[*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\Sharp-MCP-");
    @memcpy(out[0..prefix.len], prefix);
    // GetUserNameW writes the terminator and counts it.
    var size: u32 = out.len - prefix.len;
    if (w32.GetUserNameW(out[prefix.len..].ptr, &size) == 0) return null;
    return out;
}

/// Room for a TOKEN_USER and the SID after it.
pub const UserBuf = [128]u8;

/// The SID of the user `process` runs as. It points into `buf`.
pub fn userOf(process: w32.HANDLE, buf: *align(8) UserBuf) ?*anyopaque {
    var token: w32.HANDLE = undefined;
    if (w32.OpenProcessToken(process, w32.TOKEN_QUERY, &token) == 0) return null;
    defer _ = w32.CloseHandle(token);
    var len: u32 = 0;
    if (w32.GetTokenInformation(token, w32.TokenUser, buf, buf.len, &len) == 0) return null;
    // TOKEN_USER starts with the SID's pointer.
    const sid: *const ?*anyopaque = @ptrCast(buf);
    return sid.*;
}

/// Security that lets only this process's user open the pipe; the
/// default would also let everyone read it. Kept for the process's life.
pub fn ownerOnly() ?w32.SECURITY_ATTRIBUTES {
    var buf: UserBuf align(8) = undefined;
    const sid = userOf(w32.GetCurrentProcess(), &buf) orelse return null;
    var sid_text: ?[*:0]u16 = null;
    if (w32.ConvertSidToStringSidW(sid, &sid_text) == 0) return null;
    defer _ = w32.LocalFree(sid_text);
    var sddl: [256:0]u16 = undefined;
    const head = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
    const user = std.mem.span(sid_text orelse return null);
    if (head.len + user.len + 2 > sddl.len) return null;
    @memcpy(sddl[0..head.len], head);
    @memcpy(sddl[head.len..][0..user.len], user);
    sddl[head.len + user.len] = ')';
    sddl[head.len + user.len + 1] = 0;
    var descriptor: ?*anyopaque = null;
    if (w32.ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, w32.SDDL_REVISION_1, &descriptor, null) == 0) return null;
    return .{ .lpSecurityDescriptor = descriptor orelse return null };
}

/// Whether the process serving `pipe` runs as this process's user.
pub fn servedByUs(pipe: w32.HANDLE) bool {
    var pid: u32 = 0;
    if (w32.GetNamedPipeServerProcessId(pipe, &pid) == 0) return false;
    const server = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = w32.CloseHandle(server);
    var theirs_buf: UserBuf align(8) = undefined;
    var ours_buf: UserBuf align(8) = undefined;
    const theirs = userOf(server, &theirs_buf) orelse return false;
    const ours = userOf(w32.GetCurrentProcess(), &ours_buf) orelse return false;
    return w32.EqualSid(theirs, ours) != 0;
}
