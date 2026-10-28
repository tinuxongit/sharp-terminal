//! Finds the server an SSH session in a tab is connected to, so the tab
//! sidebar can list the tab under Servers. Windows sends no notice when a
//! shell starts ssh, so Window polls: the shell's process tree is searched
//! for ssh.exe and that process's command line read for its destination.
const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const windows = internal_os.windows;
const wide_string = @import("wide_string.zig");

/// How deep below the shell ssh may run (e.g. shell > script > ssh).
const max_depth = 4;

const Process = struct { pid: u32, parent: u32, ssh: bool };

/// All processes at one moment, so several tabs can be checked against
/// one snapshot.
pub const Processes = struct {
    items: [2048]Process = undefined,
    len: usize = 0,

    pub fn take() Processes {
        var self: Processes = .{};
        const snap = windows.exp.kernel32.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0);
        if (snap == windows.INVALID_HANDLE_VALUE) return self;
        defer _ = windows.exp.kernel32.CloseHandle(snap);
        var entry: windows.PROCESSENTRY32W = .{};
        var more = windows.exp.kernel32.Process32FirstW(snap, &entry) != windows.FALSE;
        while (more and self.len < self.items.len) : (more = windows.exp.kernel32.Process32NextW(snap, &entry) != windows.FALSE) {
            self.items[self.len] = .{
                .pid = entry.th32ProcessID,
                .parent = entry.th32ParentProcessID,
                .ssh = isSsh(std.mem.sliceTo(&entry.szExeFile, 0)),
            };
            self.len += 1;
        }
        return self;
    }

    /// Where the shell `shell_pid` is connected to through ssh ("user@host"
    /// or "host"), written into `out`, or null when it isn't running ssh.
    /// A tab opened on a server runs ssh as its shell.
    pub fn host(self: *const Processes, shell_pid: u32, out: []u8) ?[]const u8 {
        const procs = self.items[0..self.len];
        for (procs) |p| {
            if (!p.ssh or (p.pid != shell_pid and !descends(procs, p, shell_pid))) continue;
            var line: [2048]u8 = undefined;
            const command_line = commandLine(p.pid, &line) orelse continue;
            const destination = parseDestination(command_line) orelse continue;
            const len = @min(destination.len, out.len);
            @memcpy(out[0..len], destination[0..len]);
            return out[0..len];
        }
        return null;
    }
};

fn isSsh(exe: []const u16) bool {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ssh.exe");
    if (exe.len != name.len) return false;
    for (exe, name) |a, b| {
        if (a >= 0x80 or std.ascii.toLower(@intCast(a)) != b) return false;
    }
    return true;
}

fn descends(procs: []const Process, p: Process, ancestor: u32) bool {
    var parent = p.parent;
    for (0..max_depth) |_| {
        if (parent == ancestor) return true;
        parent = for (procs) |q| {
            if (q.pid == parent) break q.parent;
        } else return false;
    }
    return false;
}

fn commandLine(pid: u32, out: []u8) ?[]const u8 {
    const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w32.CloseHandle(process);
    // The answer is a UNICODE_STRING followed by the text it points to.
    var buf: [4096]u8 align(@alignOf(w32.UNICODE_STRING)) = undefined;
    if (w32.NtQueryInformationProcess(process, w32.ProcessCommandLineInformation, &buf, buf.len, null) < 0) return null;
    const text: *const w32.UNICODE_STRING = @ptrCast(&buf);
    const chars = text.Buffer orelse return null;
    const len = wide_string.toUtf8(out, chars[0 .. text.Length / 2]);
    return out[0..len];
}

/// The destination from an ssh command line: the first argument that
/// isn't an option, without "ssh://" or a port.
pub fn parseDestination(command_line: []const u8) ?[]const u8 {
    // ssh options that take a value, per its manual.
    const with_value = "BbcDEeFIiJLlmOoPpQRSWw";
    var args = Args{ .rest = command_line };
    _ = args.next() orelse return null; // the program itself
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) return destinationPart(args.next() orelse return null);
        if (arg.len >= 2 and arg[0] == '-') {
            // "-p 22" takes the next argument; "-p22" carries its value.
            if (arg.len == 2 and std.mem.indexOfScalar(u8, with_value, arg[1]) != null) _ = args.next();
            continue;
        }
        return destinationPart(arg);
    }
    return null;
}

fn destinationPart(destination: []const u8) ?[]const u8 {
    var d = destination;
    if (std.mem.startsWith(u8, d, "ssh://")) {
        d = d["ssh://".len..];
        if (std.mem.indexOfScalar(u8, d, '/')) |i| d = d[0..i];
        const host_start = if (std.mem.lastIndexOfScalar(u8, d, '@')) |i| i + 1 else 0;
        if (std.mem.indexOfScalarPos(u8, d, host_start, ':')) |i| d = d[0..i];
    }
    return if (d.len == 0) null else d;
}

/// Splits a Windows command line on spaces, honoring double quotes.
const Args = struct {
    rest: []const u8,

    fn next(self: *Args) ?[]const u8 {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
        if (self.rest.len == 0) return null;
        if (self.rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '"') orelse self.rest.len;
            const arg = self.rest[1..end];
            self.rest = self.rest[@min(end + 1, self.rest.len)..];
            return arg;
        }
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        const arg = self.rest[0..end];
        self.rest = self.rest[end..];
        return arg;
    }
};
