//! Copy and paste with Windows' keys (`clipboard-keys = windows`, the
//! default): Ctrl+C copies only when text is selected and otherwise
//! reaches the program as an interrupt, as in Windows Terminal; Ctrl+V
//! pastes only when the clipboard holds text or files, so with an image on
//! it the key reaches the program, which can read the image itself (Claude
//! Code does). Ghostty's Ctrl+Shift+C and Ctrl+Shift+V keep working.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const input = @import("../../input.zig");

const log = std.log.scoped(.win32);

/// Add the bindings to the loaded config, leaving any the user made for
/// Ctrl+C or Ctrl+V in the file alone.
pub fn apply(config: *Config) void {
    if (config.@"clipboard-keys" != .windows) return;
    const arena = if (config._arena) |*a| a else return;
    const alloc = arena.allocator();
    for ([_]struct { u21, []const u8 }{
        .{ 'c', "performable:ctrl+c=copy_to_clipboard" },
        .{ 'v', "performable:ctrl+v=paste_from_clipboard" },
    }) |entry| {
        const key, const binding = entry;
        if (boundByUser(config, key)) continue;
        config.keybind.parseCLI(alloc, binding) catch |err| log.warn("could not bind {s}: {}", .{ binding, err });
    }
}

fn boundByUser(config: *const Config, key: u21) bool {
    const set = &config.keybind.set;
    const physical: input.Key = if (key == 'c') .key_c else .key_v;
    return set.get(.{ .mods = .{ .ctrl = true }, .key = .{ .unicode = key } }) != null or
        set.get(.{ .mods = .{ .ctrl = true }, .key = .{ .physical = physical } }) != null;
}
