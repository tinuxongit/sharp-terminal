//! Which Claude Code conversation a tab is running, so the sidebar layout
//! can resume it when Sharp reopens the tab. Claude Code keeps a file per
//! running claude.exe, `<config>/sessions/<pid>.json`, with its session id
//! and folder, and rewrites it when the conversation changes (/clear,
//! /resume). Sharp only reads it. <config> is CLAUDE_CONFIG_DIR, else
//! .claude in the user's profile, as Claude Code decides.
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const process_tree = @import("process_tree.zig");
const wide_string = @import("wide_string.zig");
const json_read = @import("json_read.zig");

pub const id_len = 36;

pub const Session = struct {
    id: [id_len]u8,
    /// Where Claude Code runs, which decides where its conversations are
    /// kept, so a resume must start there.
    folder_buf: [260]u8 = undefined,
    folder_len: u16 = 0,

    pub fn folder(self: *const Session) []const u8 {
        return self.folder_buf[0..self.folder_len];
    }

    pub fn eql(a: ?Session, b: ?Session) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return std.mem.eql(u8, &x.id, &y.id) and std.mem.eql(u8, x.folder(), y.folder());
    }
};

/// The session of the first claude.exe that is `shell_pid` or runs below it.
pub fn find(procs: *const process_tree.Processes, shell_pid: u32) ?Session {
    var found: [16]process_tree.Process = undefined;
    for (procs.below(shell_pid, &found)) |p| {
        if (p.program != .claude) continue;
        return read(p.pid) orelse continue;
    }
    return null;
}

pub fn read(pid: u32) ?Session {
    var dir_buf: [1024]u8 = undefined;
    const dir = configDir(&dir_buf) orelse return null;
    var path_buf: [1200]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\sessions\\{d}.json", .{ dir, pid }) catch return null;
    const alloc = std.heap.smp_allocator;
    const text = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(64 * 1024)) catch return null;
    defer alloc.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    // A file left by an earlier process with the same pid isn't this one's.
    if ((json_read.number(v, "pid") orelse return null) != @as(f64, @floatFromInt(pid))) return null;
    const id = json_read.string(v, "sessionId") orelse return null;
    if (!validId(id)) return null;
    var session: Session = .{ .id = id[0..id_len].* };
    if (json_read.string(v, "cwd")) |cwd| {
        if (validFolder(cwd)) {
            @memcpy(session.folder_buf[0..cwd.len], cwd);
            session.folder_len = @intCast(cwd.len);
        }
    }
    return session;
}

fn configDir(out: []u8) ?[]const u8 {
    var wide: [512]u16 = undefined;
    const set = w32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("CLAUDE_CONFIG_DIR"), &wide, wide.len);
    if (set > 0 and set < wide.len) return out[0..wide_string.toUtf8(out, wide[0..set])];
    const home = w32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &wide, wide.len);
    if (home == 0 or home >= wide.len) return null;
    const len = wide_string.toUtf8(out, wide[0..home]);
    const suffix = "\\.claude";
    if (len + suffix.len > out.len) return null;
    @memcpy(out[len..][0..suffix.len], suffix);
    return out[0 .. len + suffix.len];
}

/// Whether `s` is a session id: a UUID, so it is safe to type into any
/// shell and to keep in the session file.
pub fn validId(s: []const u8) bool {
    if (s.len != id_len) return false;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A drive path the session file can hold: no `|`, which separates its
/// fields, and nothing a shell or the file could misread.
fn validFolder(s: []const u8) bool {
    if (s.len < 3 or s.len >= 260 or !std.ascii.isAlphabetic(s[0]) or s[1] != ':' or s[2] != '\\') return false;
    for (s) |c| if (c < 0x20 or c == '|' or c == '"') return false;
    return true;
}

/// Whether Claude Code kept conversation `id`, run in `folder`: it saves
/// one only once a message is sent, so a session that never got one has
/// nothing to resume. Its file is <config>/projects/<folder with every
/// character but letters and digits turned into '-'>/<id>.jsonl.
pub fn saved(id: []const u8, folder: []const u8) bool {
    if (!validId(id)) return false;
    var dir_buf: [1024]u8 = undefined;
    const dir = configDir(&dir_buf) orelse return false;
    var project: [260]u8 = undefined;
    if (folder.len > project.len) return false;
    for (folder, project[0..folder.len]) |c, *out| out.* = if (std.ascii.isAlphanumeric(c)) c else '-';
    var path: [1600]u8 = undefined;
    const text = std.fmt.bufPrint(&path, "{s}\\projects\\{s}\\{s}.jsonl", .{ dir, project[0..folder.len], id }) catch return false;
    var wide: [1600:0]u16 = undefined;
    const len = wide_string.fromUtf8(&wide, text);
    wide[len] = 0;
    return w32.GetFileAttributesW(&wide) != w32.INVALID_FILE_ATTRIBUTES;
}

/// What a shell is sent to resume session `id`: the command and Enter.
pub fn resumeCommand(out: []u8, id: []const u8) ?[]const u8 {
    if (!validId(id)) return null;
    return std.fmt.bufPrint(out, "claude --resume {s}\r", .{id}) catch null;
}
