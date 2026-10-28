//! Settings per shell, as Windows Terminal's profiles carry their own: a
//! file `profiles\<shell name>.ghostty` beside the config file holds any
//! Ghostty options for that shell's tabs (font, theme, colors, folder,
//! padding, ...), loaded after the user's own config. Settings > Advanced
//! opens the folder.
const std = @import("std");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const background_style = @import("background_style.zig");
const clipboard_keys = @import("clipboard_keys.zig");

const log = std.log.scoped(.profile_config);

const folder_name = "profiles";
const extension = ".ghostty";

/// The folder of the shells' files, beside the config file.
pub fn folder(alloc: std.mem.Allocator) ![]u8 {
    const config_path = try configpkg.edit.openPath(alloc);
    defer alloc.free(config_path);
    const dir = std.fs.path.dirname(config_path) orelse return error.NoConfigFolder;
    return std.fs.path.join(alloc, &.{ dir, folder_name });
}

/// The config of shell `name`'s tabs when it has a file of its own: the
/// user's config with that file applied on top, built as Sharp builds its
/// own (App.loadConfig). Null when it has none.
pub fn load(alloc: std.mem.Allocator, name: []const u8) ?Config {
    // A profile name becomes a file name: one that can't be is skipped.
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\\/:*?\"<>|") != null) return null;
    const dir = folder(alloc) catch return null;
    defer alloc.free(dir);
    const file = std.mem.concat(alloc, u8, &.{ dir, "\\", name, extension }) catch return null;
    defer alloc.free(file);
    std.Io.Dir.cwd().access(@import("../../global.zig").io(), file, .{}) catch return null;

    var config = Config.default(alloc) catch return null;
    build(&config, alloc, file) catch |err| {
        log.warn("could not read the settings of shell {s}: {}", .{ name, err });
        config.deinit();
        return null;
    };
    background_style.apply(&config);
    clipboard_keys.apply(&config);
    return config;
}

fn build(config: *Config, alloc: std.mem.Allocator, file: []const u8) !void {
    try config.loadDefaultFiles(alloc);
    try config.loadCliArgs(alloc);
    try config.loadFile(alloc, file);
    try config.loadRecursiveFiles(alloc);
    try config.finalize();
}
