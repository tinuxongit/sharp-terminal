//! cmd.exe has no shell integration, but its prompt may carry escape
//! sequences: prefixing PROMPT with OSC 7 makes it report its folder at
//! every prompt, so new tabs inherit it and Sharp's tab sidebar can group
//! tabs by folder. Other shells ignore PROMPT.
const std = @import("std");
const EnvMap = std.process.Environ.Map;

/// $e is ESC and $P the current path; the report ends with ESC \.
const report = "$e]7;file://localhost/$P$e\\";

pub fn setup(env: *EnvMap) !void {
    // cmd's default prompt is $P$G ("C:\dir>").
    const current = env.get("PROMPT") orelse "$P$G";
    if (std.mem.startsWith(u8, current, report)) return;
    const updated = try std.fmt.allocPrint(env.allocator, "{s}{s}", .{ report, current });
    defer env.allocator.free(updated);
    try env.put("PROMPT", updated);
}
