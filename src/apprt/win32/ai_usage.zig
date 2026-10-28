//! How much of Claude's and OpenCode's usage is spent, for the Workspace
//! sidebar's AI section. Each tool is asked through its own CLI, as T3
//! Code does, so Sharp holds no keys and whether a subscription or an API
//! key pays is the CLI's business:
//!
//! - Claude Code, started in stream-json mode, answers the control request
//!   `get_usage` (what its /usage shows) with the plan's 5-hour and weekly
//!   windows. No prompt is ever sent, and hooks and MCP servers stay off.
//!   Anthropic's Agent SDK marks the request experimental, so the reply
//!   is read loosely and a failed read keeps the last good one.
//! - OpenCode's `stats --json --cost` gives cost and tokens over N days.
//!
//! A background thread asks every few minutes and posts a message to the
//! app, which repaints the sidebars.
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const profiles = @import("profiles.zig");
const wide_string = @import("wide_string.zig");

const windows = internal_os.windows;
const kernel32 = windows.exp.kernel32;
const log = std.log.scoped(.ai_usage);

/// A plan's usage window: how much is used and when it starts over.
pub const Window = struct {
    percent: f32,
    /// Unix seconds, or 0 when unknown.
    resets_at: i64,
};

pub const Spend = struct {
    cost_usd: f64,
    tokens: u64,
};

pub const Snapshot = struct {
    claude_found: bool = false,
    /// Plan windows; null with an API key, which has no plan limits.
    five_hour: ?Window = null,
    seven_day: ?Window = null,
    /// Whether Claude answered at all, so an API key can be told apart
    /// from no answer yet.
    claude_answered: bool = false,
    opencode_found: bool = false,
    opencode_today: ?Spend = null,
    opencode_week: ?Spend = null,

    pub fn any(self: Snapshot) bool {
        return self.claude_found or self.opencode_found;
    }
};

var lock: std.Io.Mutex = .init;
var latest: Snapshot = .{};
var started = false;

/// The latest usage, for painting.
pub fn snapshot() Snapshot {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    return latest;
}

/// Start asking, once; `notify` gets `message` after every answer.
/// Called when a sidebar first paints, so Tabs mode never spawns the CLIs.
pub fn ensureStarted(notify: w32.HWND, message: u32) void {
    if (started) return;
    started = true;
    const thread = std.Thread.spawn(.{}, poll, .{ notify, message }) catch |err| {
        log.warn("failed to start the usage thread: {}", .{err});
        return;
    };
    thread.detach();
}

fn poll(notify: w32.HWND, message: u32) void {
    const alloc = std.heap.page_allocator;
    while (true) {
        var next = snapshot();
        next.claude_found = findProgram("claude.exe");
        if (next.claude_found) readClaude(alloc, &next);
        next.opencode_found = findProgram("opencode.cmd") or findProgram("opencode.exe");
        if (next.opencode_found) {
            next.opencode_today = readOpenCode(alloc, 0) orelse next.opencode_today;
            next.opencode_week = readOpenCode(alloc, 7) orelse next.opencode_week;
        }
        {
            lock.lockUncancelable(global.io());
            defer lock.unlock(global.io());
            latest = next;
        }
        _ = w32.PostMessageW(notify, message, 0, 0);
        w32.Sleep(@as(u32, profiles.data.sidebar.ai.refresh_minutes) * 60 * 1000);
    }
}

fn findProgram(name: []const u8) bool {
    return profiles.programExists(name);
}

/// Claude Code's /usage through its control protocol. On any failure the
/// previous windows stay.
fn readClaude(alloc: std.mem.Allocator, into: *Snapshot) void {
    // The JSON's quotes are escaped: Windows strips bare ones from arguments.
    var cli = Cli.start("claude.exe --output-format stream-json --verbose --input-format stream-json " ++
        "--settings \"{\\\"disableAllHooks\\\":true}\" --strict-mcp-config") orelse return;
    defer cli.end();
    cli.write("{\"type\":\"control_request\",\"request_id\":\"init\",\"request\":{\"subtype\":\"initialize\"}}\n");
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);
    while (cli.readLine(alloc, &line_buf)) |line| {
        defer alloc.free(line);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const response = field(parsed.value, "response") orelse continue;
        if (!eqlString(field(parsed.value, "type"), "control_response")) continue;
        const id = field(response, "request_id");
        if (eqlString(id, "init")) {
            cli.write("{\"type\":\"control_request\",\"request_id\":\"usage\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n");
        } else if (eqlString(id, "usage")) {
            if (!eqlString(field(response, "subtype"), "success")) return;
            const usage = field(response, "response") orelse return;
            into.claude_answered = true;
            const limits = field(usage, "rate_limits");
            into.five_hour = if (limits) |l| window(field(l, "five_hour")) else null;
            into.seven_day = if (limits) |l| window(field(l, "seven_day")) else null;
            return;
        }
    }
}

fn window(value: ?std.json.Value) ?Window {
    const v = value orelse return null;
    const percent: f32 = switch (field(v, "utilization") orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => return null,
    };
    const resets_at = if (field(v, "resets_at")) |r| switch (r) {
        .string => |s| parseIso8601(s) orelse 0,
        else => 0,
    } else 0;
    return .{ .percent = std.math.clamp(percent, 0, 100), .resets_at = resets_at };
}

/// OpenCode's spending over the last `days` (0 is today).
fn readOpenCode(alloc: std.mem.Allocator, days: u8) ?Spend {
    var cmd: [96]u8 = undefined;
    // opencode is an npm shim (opencode.cmd), which only cmd.exe can run.
    // --standalone runs a private server that ends with the command, rather
    // than leaving OpenCode's background service started behind.
    const command = std.fmt.bufPrint(&cmd, "cmd.exe /d /c opencode stats --standalone --json --cost --days {d}", .{days}) catch return null;
    var cli = Cli.start(command) orelse return null;
    defer cli.end();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    cli.readAll(alloc, &out);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out.items, .{}) catch return null;
    defer parsed.deinit();
    const tokens = field(parsed.value, "tokens");
    var total: u64 = 0;
    inline for (.{ "input", "output", "reasoning" }) |kind| {
        if (tokens) |t| total += number(u64, field(t, kind));
    }
    return .{ .cost_usd = number(f64, field(parsed.value, "cost")), .tokens = total };
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn eqlString(value: ?std.json.Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}

fn number(comptime T: type, value: ?std.json.Value) T {
    const v = value orelse return 0;
    return switch (v) {
        .integer => |i| if (T == f64) @floatFromInt(i) else @intCast(@max(i, 0)),
        .float => |f| if (T == f64) f else @intFromFloat(@max(f, 0)),
        else => 0,
    };
}

/// Unix seconds from "2026-10-28T11:29:59.552523+00:00" or "...Z".
pub fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    var t = days * 86400 + h * 3600 + mi * 60 + se;
    // A "+hh:mm" or "-hh:mm" offset after the seconds and their fraction.
    if (std.mem.lastIndexOfAny(u8, s[19..], "+-")) |i| {
        const off = s[19 + i ..];
        if (off.len >= 6) {
            const oh = std.fmt.parseInt(i64, off[1..3], 10) catch 0;
            const om = std.fmt.parseInt(i64, off[4..6], 10) catch 0;
            const sign: i64 = if (off[0] == '-') -1 else 1;
            t -= sign * (oh * 3600 + om * 60);
        }
    }
    return t;
}

/// A CLI run with its output (and input) on pipes, never longer than
/// `timeout_ms`, and with no console window.
const Cli = struct {
    process: windows.HANDLE,
    stdin_w: windows.HANDLE,
    stdout_r: windows.HANDLE,
    started_ms: u64,

    const timeout_ms = 30_000;

    fn start(command_line: []const u8) ?Cli {
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
        // Only the child's ends are inherited.
        _ = kernel32.SetHandleInformation(out_r, windows.HANDLE_FLAG_INHERIT, 0);
        _ = kernel32.SetHandleInformation(in_w, windows.HANDLE_FLAG_INHERIT, 0);
        defer _ = kernel32.CloseHandle(out_w);
        defer _ = kernel32.CloseHandle(in_r);

        var wide: [512:0]u16 = undefined;
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
        return .{ .process = info.hProcess, .stdin_w = in_w, .stdout_r = out_r, .started_ms = w32.GetTickCount64() };
    }

    fn write(self: *Cli, bytes: []const u8) void {
        var written: windows.DWORD = 0;
        _ = kernel32.WriteFile(self.stdin_w, bytes.ptr, @intCast(bytes.len), &written, null);
    }

    fn timedOut(self: *const Cli) bool {
        return w32.GetTickCount64() - self.started_ms > timeout_ms;
    }

    /// Read what is waiting, without blocking; false once the output has
    /// ended (or the time is up).
    fn pump(self: *Cli, alloc: std.mem.Allocator, into: *std.ArrayList(u8)) bool {
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

    /// The next line of output, which the caller frees, or null once the
    /// output has ended. `buf` holds what was read past it.
    fn readLine(self: *Cli, alloc: std.mem.Allocator, buf: *std.ArrayList(u8)) ?[]u8 {
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

    fn readAll(self: *Cli, alloc: std.mem.Allocator, into: *std.ArrayList(u8)) void {
        while (self.pump(alloc, into)) {}
    }

    fn end(self: *Cli) void {
        _ = kernel32.TerminateProcess(self.process, 0);
        _ = kernel32.CloseHandle(self.process);
        _ = kernel32.CloseHandle(self.stdin_w);
        _ = kernel32.CloseHandle(self.stdout_r);
    }
};
