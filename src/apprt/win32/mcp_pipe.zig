//! The named pipe between Sharp's MCP server and the sharp-mcp bridge that
//! Claude Code starts. Its name carries the Windows user, so each account
//! reaches its own Sharp.
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
