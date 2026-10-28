//! On Windows, the programs a terminal tab started, and which of them end
//! with it. Each tab's shell starts inside its own Job Object, which every
//! process it launches joins as well, even after the process in between
//! has exited (a dev server whose `npm` is gone is still found).
//!
//! Closing a tab ends its console programs: servers, builds, anything left
//! running in the background, sharing the tab's console, in a hidden one
//! or in none. Programs with a window (an editor opened with `code .`, a
//! browser opened with `start`, a console opened with `start cmd`) keep
//! running, and so does everything they launch, as they would after
//! closing Windows Terminal. If Sharp crashes, every tab's console
//! programs end too (endAll).
const std = @import("std");
const windows = @import("windows.zig");

const kernel32 = windows.exp.kernel32;
const user32 = windows.exp.user32;

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
        if (pid == shell_pid or underWindow(pid, shell_pid, members, &tree) or ownConsole(pid, &tree)) continue;
        out[n] = pid;
        n += 1;
    }
    return out[0..n];
}

/// Every tab's job, so a crash can end them all.
const Registered = struct { job: windows.HANDLE, shell_pid: u32 };
var registry: [256]Registered = undefined;
var registry_len: usize = 0;
var registry_busy: std.atomic.Value(bool) = .init(false);

fn lockRegistry() void {
    while (registry_busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockRegistry() void {
    registry_busy.store(false, .release);
}

/// Remember a tab's job once its shell runs.
pub fn register(job: windows.HANDLE, shell_pid: u32) void {
    lockRegistry();
    defer unlockRegistry();
    if (registry_len == registry.len) return;
    registry[registry_len] = .{ .job = job, .shell_pid = shell_pid };
    registry_len += 1;
}

/// Forget a tab's job before its handle is closed.
pub fn unregister(job: windows.HANDLE) void {
    lockRegistry();
    defer unlockRegistry();
    for (registry[0..registry_len], 0..) |r, i| {
        if (r.job != job) continue;
        registry_len -= 1;
        registry[i] = registry[registry_len];
        return;
    }
}

/// End every tab's console programs, as Sharp crashes. Never waits: if the
/// crash came while the registry was being changed, it is left alone.
pub fn endAll() void {
    if (registry_busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    defer unlockRegistry();
    for (registry[0..registry_len]) |r| end(r.job, r.shell_pid);
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

/// Whether `pid` runs in a console of its own that someone can see: a
/// visible console window (`start cmd`), or another terminal's pseudo
/// console. Sharing a Sharp tab's console, a hidden console window and
/// no console at all mean a background program.
fn ownConsole(pid: u32, tree: *const Tree) bool {
    const process = kernel32.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, pid) orelse return false;
    defer _ = kernel32.CloseHandle(process);
    var host_info: usize = 0;
    if (windows.exp.ntdll.NtQueryInformationProcess(process, windows.ProcessConsoleHostProcess, &host_info, @sizeOf(usize), null) != .SUCCESS) return false;
    // The low bits are flags, not part of the PID.
    const host: u32 = @intCast(host_info & ~@as(usize, 3));
    if (host == 0) return false;
    // Sharp's own pseudo consoles are hosted by OpenConsole.exe processes
    // it started.
    if (tree.parentOf(host) == kernel32.GetCurrentProcessId()) return false;

    var search: ConsoleWindowSearch = .{ .host = host };
    _ = user32.EnumWindows(ConsoleWindowSearch.visit, @bitCast(@intFromPtr(&search)));
    return search.shown;
}

const ConsoleWindowSearch = struct {
    host: u32,
    shown: bool = false,

    fn visit(hwnd: windows.HWND, param: windows.LPARAM) callconv(.winapi) windows.BOOL {
        const self: *ConsoleWindowSearch = @ptrFromInt(@as(usize, @bitCast(param)));
        var owner: windows.DWORD = 0;
        _ = user32.GetWindowThreadProcessId(hwnd, &owner);
        if (owner != self.host) return windows.TRUE;
        var class: [32]u16 = undefined;
        const len: usize = @intCast(@max(0, user32.GetClassNameW(hwnd, &class, class.len)));
        const pseudo = std.mem.eql(u16, class[0..len], std.unicode.utf8ToUtf16LeStringLiteral("PseudoConsoleWindow"));
        if (pseudo or user32.IsWindowVisible(hwnd) != windows.FALSE) {
            self.shown = true;
            return windows.FALSE;
        }
        return windows.TRUE;
    }
};

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
