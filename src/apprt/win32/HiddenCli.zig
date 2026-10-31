const std = @import("std");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const wide_string = @import("wide_string.zig");

const windows = internal_os.windows;
const kernel32 = windows.exp.kernel32;

const HiddenCli = @This();

process: windows.HANDLE,
stdin_w: windows.HANDLE,
stdout_r: windows.HANDLE,
started_ms: u64,
timeout_ms: u64,

const default_timeout_ms = 30_000;

pub fn start(command_line: []const u8) ?HiddenCli {
    return startWithin(command_line, default_timeout_ms);
}

pub fn startWithin(command_line: []const u8, timeout_ms: u64) ?HiddenCli {
    var wide: [8192:0]u16 = undefined;
    if (command_line.len >= wide.len) return null;
    var sa: windows.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = windows.TRUE };
    var out_r: windows.HANDLE = undefined;
    var out_w: windows.HANDLE = undefined;
    var in_r: windows.HANDLE = undefined;
    var in_w: windows.HANDLE = undefined;
    if (kernel32.CreatePipe(&out_r, &out_w, &sa, 0) == windows.FALSE) return null;
    if (kernel32.CreatePipe(&in_r, &in_w, &sa, 0) == windows.FALSE) {
        _ = kernel32.CloseHandle(out_r);
        _ = kernel32.CloseHandle(out_w);
        return null;
    }
    _ = kernel32.SetHandleInformation(out_r, windows.HANDLE_FLAG_INHERIT, 0);
    _ = kernel32.SetHandleInformation(in_w, windows.HANDLE_FLAG_INHERIT, 0);
    defer _ = kernel32.CloseHandle(out_w);
    defer _ = kernel32.CloseHandle(in_r);

    const len = wide_string.fromUtf8(&wide, command_line);
    wide[len] = 0;
    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.hStdInput = in_r;
    startup.hStdOutput = out_w;
    startup.hStdError = out_w;
    var info: windows.PROCESS_INFORMATION = undefined;
    const create_no_window = 0x08000000;
    if (kernel32.CreateProcessW(null, &wide, null, null, windows.TRUE, create_no_window, null, null, &startup, &info) == windows.FALSE) {
        _ = kernel32.CloseHandle(out_r);
        _ = kernel32.CloseHandle(in_w);
        return null;
    }
    _ = kernel32.CloseHandle(info.hThread);
    return .{ .process = info.hProcess, .stdin_w = in_w, .stdout_r = out_r, .started_ms = w32.GetTickCount64(), .timeout_ms = timeout_ms };
}

pub fn write(self: *HiddenCli, bytes: []const u8) void {
    var written: windows.DWORD = 0;
    _ = kernel32.WriteFile(self.stdin_w, bytes.ptr, @intCast(bytes.len), &written, null);
}

fn timedOut(self: *const HiddenCli) bool {
    return w32.GetTickCount64() - self.started_ms > self.timeout_ms;
}

fn pump(self: *HiddenCli, alloc: std.mem.Allocator, into: *std.ArrayList(u8)) bool {
    if (self.timedOut()) return false;
    var avail: windows.DWORD = 0;
    if (kernel32.PeekNamedPipe(self.stdout_r, null, 0, null, &avail, null) == windows.FALSE) return false;
    if (avail == 0) {
        w32.Sleep(20);
        return true;
    }
    var buf: [4096]u8 = undefined;
    var got: windows.DWORD = 0;
    if (kernel32.ReadFile(self.stdout_r, &buf, @min(buf.len, avail), &got, null) == windows.FALSE) return false;
    into.appendSlice(alloc, buf[0..got]) catch return false;
    return true;
}

pub fn readLine(self: *HiddenCli, alloc: std.mem.Allocator, buf: *std.ArrayList(u8)) ?[]u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = alloc.dupe(u8, buf.items[0..nl]) catch return null;
            const rest = buf.items.len - nl - 1;
            std.mem.copyForwards(u8, buf.items[0..rest], buf.items[nl + 1 ..]);
            buf.shrinkRetainingCapacity(rest);
            return line;
        }
        if (!self.pump(alloc, buf)) return null;
    }
}

pub fn readAll(self: *HiddenCli, alloc: std.mem.Allocator, into: *std.ArrayList(u8)) void {
    while (self.pump(alloc, into)) {}
}

pub fn end(self: *HiddenCli) void {
    _ = kernel32.TerminateProcess(self.process, 0);
    _ = kernel32.CloseHandle(self.process);
    _ = kernel32.CloseHandle(self.stdin_w);
    _ = kernel32.CloseHandle(self.stdout_r);
}
