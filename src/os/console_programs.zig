//! On Windows, the programs a terminal tab started, and which of them end
//! with it. Each tab's shell starts inside its own Job Object, which every
//! process it launches joins as well, even after the process in between
//! has exited (a dev server whose `npm` is gone is still found).
//!
//! Closing a tab ends its console programs: servers, builds, anything left
//! running in the background. Programs with a window (an editor opened
//! with `code .`, a browser opened with `start`) keep running, and so does
//! everything they launch, as they would after closing Windows Terminal.
const std = @import("std");
const windows = @import("windows.zig");

const kernel32 = windows.exp.kernel32;

pub const max_programs = 256;

/// A new job for one tab's shell, or null if Windows refused one (the tab
/// then works as before, without ending its programs).
pub fn createJob() ?windows.HANDLE {
    const job = kernel32.CreateJobObjectW(null, null) orelse return null;
    // A program that asks to leave the job (CREATE_BREAKAWAY_FROM_JOB)
    // wants to outlive its terminal; without this its launch would fail.
    var limits: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION = std.mem.zeroes(windows.JOBOBJECT_BASIC_LIMIT_INFORMATION);
    limits.LimitFlags = windows.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    _ = kernel32.SetInformationJobObject(job, windows.JobObjectBasicLimitInformation, &limits, @sizeOf(@TypeOf(limits)));
    return job;
}

/// The console programs in `job` that closing the tab would end: every
/// process but the shell itself and those under a program with a window.
pub fn list(job: windows.HANDLE, shell_pid: u32, out: *[max_programs]u32) []const u32 {
    var ids: windows.JOBOBJECT_BASIC_PROCESS_ID_LIST(max_programs) = undefined;
    // On failure the list is left as it was: start it empty, or a failed
    // query would hand back garbage PIDs to end.
    ids.NumberOfProcessIdsInList = 0;
    // With more processes than fit, Windows fails but still fills what fits.
    _ = kernel32.QueryInformationJobObject(job, windows.JobObjectBasicProcessIdList, &ids, @sizeOf(@TypeOf(ids)), null);
    const members = ids.ProcessIdList[0..@min(ids.NumberOfProcessIdsInList, max_programs)];

    const tree = Tree.take();
    var n: usize = 0;
    for (members) |member| {
        const pid: u32 = @intCast(member);
        if (pid == shell_pid or underWindow(pid, shell_pid, members, &tree)) continue;
        out[n] = pid;
        n += 1;
    }
    return out[0..n];
}

/// End the console programs in `job`, before the tab's shell is ended.
pub fn end(job: windows.HANDLE, shell_pid: u32) void {
    var buf: [max_programs]u32 = undefined;
    for (list(job, shell_pid, &buf)) |pid| {
        const process = kernel32.OpenProcess(windows.PROCESS_TERMINATE, windows.FALSE, pid) orelse continue;
        defer _ = kernel32.CloseHandle(process);
        _ = kernel32.TerminateProcess(process, 1);
    }
}

/// Whether `pid`, or a process between it and the shell, has a window.
fn underWindow(pid: u32, shell_pid: u32, members: []const usize, tree: *const Tree) bool {
    var current = pid;
    // Parent links can loop when Windows reuses a PID; stop after a while.
    for (0..32) |_| {
        if (hasWindow(current)) return true;
        const parent = tree.parentOf(current) orelse return false;
        if (parent == shell_pid or std.mem.indexOfScalar(usize, members, parent) == null) return false;
        current = parent;
    }
    return false;
}

/// Whether the program's executable is built for the Windows GUI rather
/// than the console, read from its PE header.
fn hasWindow(pid: u32) bool {
    const process = kernel32.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, pid) orelse return false;
    defer _ = kernel32.CloseHandle(process);
    var path: [windows.MAX_PATH * 2:0]u16 = undefined;
    var len: windows.DWORD = path.len;
    if (kernel32.QueryFullProcessImageNameW(process, 0, &path, &len) == windows.FALSE) return false;
    path[len] = 0;

    const file = kernel32.CreateFileW(&path, windows.GENERIC_READ, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE, null, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, null);
    if (file == windows.INVALID_HANDLE_VALUE) return false;
    defer _ = kernel32.CloseHandle(file);
    var header: [4096]u8 = undefined;
    var read: windows.DWORD = 0;
    if (kernel32.ReadFile(file, &header, header.len, &read, null) == windows.FALSE) return false;
    return subsystem(header[0..read]) == image_subsystem_windows_gui;
}

const image_subsystem_windows_gui = 2;

/// The Subsystem field of a PE image's optional header, or null when
/// `image` doesn't start like one.
fn subsystem(image: []const u8) ?u16 {
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, image[0x3C..0x40], .little);
    // "PE\0\0", the 20-byte file header, then Subsystem at 68 into the
    // optional header, for both 32- and 64-bit images.
    const field = @as(usize, pe) + 4 + 20 + 68;
    if (field + 2 > image.len or !std.mem.eql(u8, image[pe..][0..4], "PE\x00\x00")) return null;
    return std.mem.readInt(u16, image[field..][0..2], .little);
}

/// Every process's parent at one moment.
const Tree = struct {
    pids: [4096]u32 = undefined,
    parents: [4096]u32 = undefined,
    len: usize = 0,

    fn take() Tree {
        var self: Tree = .{};
        const snapshot = kernel32.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0);
        if (snapshot == windows.INVALID_HANDLE_VALUE) return self;
        defer _ = kernel32.CloseHandle(snapshot);
        var entry: windows.PROCESSENTRY32W = .{};
        var more = kernel32.Process32FirstW(snapshot, &entry) != windows.FALSE;
        while (more and self.len < self.pids.len) : (more = kernel32.Process32NextW(snapshot, &entry) != windows.FALSE) {
            self.pids[self.len] = entry.th32ProcessID;
            self.parents[self.len] = entry.th32ParentProcessID;
            self.len += 1;
        }
        return self;
    }

    fn parentOf(self: *const Tree, pid: u32) ?u32 {
        const i = std.mem.indexOfScalar(u32, self.pids[0..self.len], pid) orelse return null;
        return self.parents[i];
    }
};
