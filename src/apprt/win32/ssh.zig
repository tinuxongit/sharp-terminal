//! Finds the server an SSH session in a tab is connected to, so the tab
//! sidebar can list the tab under Servers. Windows sends no notice when a
//! shell starts ssh, so Window polls: the shell's process tree is searched
//! for an SSH client (OpenSSH's ssh.exe, PuTTY's plink.exe, or wsl.exe
//! running ssh) and its command line read for the destination.
const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const windows = internal_os.windows;
const wide_string = @import("wide_string.zig");

/// How deep below the shell ssh may run (e.g. shell > script > ssh).
const max_depth = 4;

/// The programs whose command lines can name a server.
const Client = enum { none, ssh, plink, wsl };

const Process = struct { pid: u32, parent: u32, client: Client };

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
                .client = clientOf(std.mem.sliceTo(&entry.szExeFile, 0)),
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
            if (p.client == .none or (p.pid != shell_pid and !descends(procs, p, shell_pid))) continue;
            var line: [2048]u8 = undefined;
            const command_line = commandLine(p.pid, &line) orelse continue;
            var dest_buf: [256]u8 = undefined;
            const destination = switch (p.client) {
                .none => unreachable,
                .ssh => parseDestination(command_line, &dest_buf),
                .plink => parsePlink(command_line, &dest_buf),
                .wsl => parseWsl(command_line, &dest_buf),
            } orelse continue;
            const len = @min(destination.len, out.len);
            @memcpy(out[0..len], destination[0..len]);
            return out[0..len];
        }
        return null;
    }
};

fn clientOf(exe: []const u16) Client {
    inline for (.{ .{ "ssh.exe", Client.ssh }, .{ "plink.exe", Client.plink }, .{ "wsl.exe", Client.wsl } }) |c| {
        if (exeIs(exe, c[0])) return c[1];
    }
    return .none;
}

fn exeIs(exe: []const u16, comptime name: []const u8) bool {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(name);
    if (exe.len != wide.len) return false;
    for (exe, wide) |a, b| {
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
/// isn't an option, with the user from `-l` if it has none, and without
/// "ssh://" or a port. Written into `out`.
pub fn parseDestination(command_line: []const u8, out: []u8) ?[]const u8 {
    var args = Args{ .rest = command_line };
    _ = args.next() orelse return null; // the program itself
    return sshArgs(&args, out);
}

fn sshArgs(args: *Args, out: []u8) ?[]const u8 {
    // ssh options that take a value, per its manual.
    const with_value = "BbcDEeFIiJLlmOoPpQRSWw";
    var user: []const u8 = "";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) return withUser(destinationPart(args.next() orelse return null) orelse return null, user, out);
        if (arg.len >= 2 and arg[0] == '-') {
            // "-l me" takes the next argument; "-lme" carries its value.
            if (std.mem.indexOfScalar(u8, with_value, arg[1]) == null) continue;
            const value = if (arg.len > 2) arg[2..] else args.next() orelse return null;
            if (arg[1] == 'l') user = value;
            continue;
        }
        return withUser(destinationPart(arg) orelse return null, user, out);
    }
    return null;
}

/// The destination from a plink command line. Its options differ from
/// ssh's: "-P port", "-l user", "-load session" (which names the server
/// when no host follows).
fn parsePlink(command_line: []const u8, out: []u8) ?[]const u8 {
    const with_value = [_][]const u8{ "-P", "-l", "-pw", "-pwfile", "-i", "-L", "-R", "-D", "-m", "-hostkey", "-sercfg", "-load", "-proxycmd", "-sshlog", "-sshrawlog", "-ca" };
    var args = Args{ .rest = command_line };
    _ = args.next() orelse return null;
    var user: []const u8 = "";
    var session: ?[]const u8 = null;
    next: while (args.next()) |arg| {
        if (arg.len >= 2 and arg[0] == '-') {
            for (with_value) |option| {
                if (!std.mem.eql(u8, arg, option)) continue;
                const value = args.next() orelse return null;
                if (std.mem.eql(u8, option, "-l")) user = value;
                if (std.mem.eql(u8, option, "-load")) session = value;
                continue :next;
            }
            continue;
        }
        return withUser(destinationPart(arg) orelse return null, user, out);
    }
    return withUser(session orelse return null, user, out);
}

/// The destination of `wsl.exe [options] [-e | --exec | --] ssh ...`, run
/// from a Windows shell. A tab whose shell is wsl.exe itself runs no ssh.
fn parseWsl(command_line: []const u8, out: []u8) ?[]const u8 {
    const with_value = [_][]const u8{ "-d", "--distribution", "-u", "--user", "--cd", "--shell-type" };
    var args = Args{ .rest = command_line };
    _ = args.next() orelse return null;
    next: while (args.next()) |arg| {
        for (with_value) |option| {
            if (std.mem.eql(u8, arg, option)) {
                _ = args.next() orelse return null;
                continue :next;
            }
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec") or std.mem.eql(u8, arg, "--")) continue;
        if (arg.len > 0 and arg[0] == '-') continue;
        // The command WSL runs: only ssh names a server.
        const program = arg[if (std.mem.lastIndexOfScalar(u8, arg, '/')) |i| i + 1 else 0..];
        if (!std.mem.eql(u8, program, "ssh")) return null;
        return sshArgs(&args, out);
    }
    return null;
}

/// "user@host" when `user` came from an option and `destination` has none.
fn withUser(destination: []const u8, user: []const u8, out: []u8) ?[]const u8 {
    if (user.len == 0 or std.mem.indexOfScalar(u8, destination, '@') != null) return destination;
    return std.fmt.bufPrint(out, "{s}@{s}", .{ user, destination }) catch null;
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
