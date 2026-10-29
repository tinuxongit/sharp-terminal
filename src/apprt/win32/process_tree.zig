//! All processes at one moment, and which of them run below a tab's
//! shell. Windows sends no notice when a shell starts a program, so the
//! sidebar layout polls: ssh.zig finds SSH sessions this way, and
//! claude_session.zig Claude Code's.
const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const windows = internal_os.windows;
const wide_string = @import("wide_string.zig");

/// How deep below the shell a program may run (e.g. shell > script > ssh).
const max_depth = 4;

/// The programs a tab is checked for.
pub const Program = enum { other, ssh, plink, wsl, claude };

pub const Process = struct { pid: u32, parent: u32, program: Program };

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
                .program = programOf(std.mem.sliceTo(&entry.szExeFile, 0)),
            };
            self.len += 1;
        }
        return self;
    }

    /// The checked-for programs that are `shell_pid` or run below it,
    /// written into `out`.
    pub fn below(self: *const Processes, shell_pid: u32, out: []Process) []const Process {
        var n: usize = 0;
        const procs = self.items[0..self.len];
        for (procs) |p| {
            if (p.program == .other or (p.pid != shell_pid and !descends(procs, p, shell_pid))) continue;
            if (n == out.len) break;
            out[n] = p;
            n += 1;
        }
        return out[0..n];
    }

    pub fn find(self: *const Processes, pid: u32) ?Process {
        for (self.items[0..self.len]) |p| if (p.pid == pid) return p;
        return null;
    }
};

fn programOf(exe: []const u16) Program {
    inline for (.{ .{ "ssh.exe", Program.ssh }, .{ "plink.exe", Program.plink }, .{ "wsl.exe", Program.wsl }, .{ "claude.exe", Program.claude } }) |c| {
        if (exeIs(exe, c[0])) return c[1];
    }
    return .other;
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

/// A process's command line, written into `out`.
pub fn commandLine(pid: u32, out: []u8) ?[]const u8 {
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
