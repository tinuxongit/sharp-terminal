//! cmd.exe has no shell integration, but its prompt may carry escape
//! sequences: prefixing PROMPT with OSC 7 makes it report its folder at
//! every prompt, so new tabs inherit it and Sharp's tab sidebar can group
//! tabs by folder. Prompt marks (OSC 133) around it tell where typing
//! starts, so Sharp can keep cmd's commands across tabs
//! (apprt/win32/command_history.zig). Other shells ignore PROMPT.
const std = @import("std");
const EnvMap = std.process.Environ.Map;

/// $e is ESC and $P the current path; the report ends with ESC \.
/// cmd never redraws its prompt, so a resize must not clear it.
const before = "$e]7;file://localhost/$P$e\\$e]133;A;redraw=0$e\\";
/// Typing starts here. 133;I (typing ends with the line) would suit cmd
/// better, since it never marks a command's start, but ConPTY answers
/// that one by asking the terminal for the cursor on every prompt.
const after = "$e]133;B$e\\";

pub fn setup(env: *EnvMap) !void {
    // cmd's default prompt is $P$G ("C:\dir>").
    const current = env.get("PROMPT") orelse "$P$G";
    if (std.mem.startsWith(u8, current, before)) return;
    const updated = try std.fmt.allocPrint(env.allocator, "{s}{s}{s}", .{ before, current, after });
    defer env.allocator.free(updated);
    try env.put("PROMPT", updated);
}
