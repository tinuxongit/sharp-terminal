//! The environment a new tab starts with: Sharp's own, updated with the
//! user's variables as Windows has them now, as Windows Terminal does
//! (`reloadEnvironmentVariables`). A PATH changed by an installer since
//! Sharp started reaches the next tab without restarting Sharp, while
//! variables only the program that launched Sharp set still pass through.
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");

const log = std.log.scoped(.user_environment);

extern "userenv" fn CreateEnvironmentBlock(env: *?[*]u16, token: ?w32.HANDLE, inherit: i32) callconv(.winapi) i32;
extern "userenv" fn DestroyEnvironmentBlock(env: [*]u16) callconv(.winapi) i32;

pub fn current() !std.process.Environ.Map {
    var env = try global.environMap();
    errdefer env.deinit();

    var token: w32.HANDLE = undefined;
    if (w32.OpenProcessToken(w32.GetCurrentProcess(), w32.TOKEN_QUERY | TOKEN_DUPLICATE, &token) == 0) return env;
    defer _ = w32.CloseHandle(token);
    var block: ?[*]u16 = null;
    // Not inheriting: Windows' variables alone, as a new sign-in has them.
    if (CreateEnvironmentBlock(&block, token, 0) == 0) {
        log.warn("could not read the user's environment, new tabs keep Sharp's", .{});
        return env;
    }
    defer _ = DestroyEnvironmentBlock(block.?);

    // "NAME=value\0" entries, ended by an empty one. Names starting with
    // "=" are the shell's per-drive folders, not variables.
    const alloc = std.heap.smp_allocator;
    var i: usize = 0;
    while (block.?[i] != 0) {
        const entry = std.mem.sliceTo(block.? + i, 0);
        i += entry.len + 1;
        if (entry[0] == '=') continue;
        const text = try std.unicode.wtf16LeToWtf8Alloc(alloc, entry);
        defer alloc.free(text);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        try env.put(text[0..eq], text[eq + 1 ..]);
    }
    return env;
}

const TOKEN_DUPLICATE: u32 = 0x0002;
