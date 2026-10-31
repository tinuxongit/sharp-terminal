//! How much of Claude's, Codex's and OpenCode's usage is spent, for the
//! Workspace sidebar's AI section. Each tool is asked through its own CLI,
//! as T3 Code does, so Sharp holds no keys and whether a subscription or
//! an API key pays is the CLI's business:
//!
//! - Claude Code, started in stream-json mode, answers the control request
//!   `get_usage` (what its /usage shows) with the plan's 5-hour and weekly
//!   windows. No prompt is ever sent, and hooks and MCP servers stay off.
//!   Anthropic's Agent SDK marks the request experimental, so the reply
//!   is read loosely and a failed read keeps the last good one.
//! - Codex's `app-server` answers the JSON-RPC request
//!   `account/rateLimits/read` with the ChatGPT plan's windows: 5-hour and
//!   weekly on paid plans, monthly on Free.
//! - OpenCode's `stats --json --cost` gives cost and tokens over N days.
//!
//! A background thread asks every few minutes and posts a message to the
//! app, which repaints the sidebars. Each tool can be switched off in
//! Settings > AI (the `ai-usage-*` config keys).
const std = @import("std");
const w32 = @import("win32.zig");
const global = @import("../../global.zig");
const profiles = @import("profiles.zig");
const HiddenCli = @import("HiddenCli.zig");

const log = std.log.scoped(.ai_usage);

/// A plan's usage window: how much is used and when it starts over.
pub const Window = struct {
    percent: f32,
    /// Unix seconds, or 0 when unknown.
    resets_at: i64,
    /// How long the window lasts, which names it (5 h, week, month).
    minutes: u32,
    kind: Kind,
    /// The model a per-model window counts, as the CLI names it ("Fable").
    model_buf: [24]u8 = undefined,
    model_len: u8 = 0,

    /// What a window limits, which Settings > AI can hide: the short window
    /// (5 hours, or a month on Codex's Free plan), the weekly one, or one
    /// model's own.
    pub const Kind = enum { session, weekly, model };

    pub fn model(self: *const Window) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    fn named(self: Window, name: []const u8) Window {
        var w = self;
        w.model_len = @intCast(@min(name.len, w.model_buf.len));
        @memcpy(w.model_buf[0..w.model_len], name[0..w.model_len]);
        return w;
    }
};

pub const max_windows = 6;

/// A subscription's windows, as Claude or Codex report them.
pub const Plan = struct {
    found: bool = false,
    /// Whether the CLI answered at all, so "no plan limits" (an API key)
    /// can be told apart from no answer yet.
    answered: bool = false,
    windows: [max_windows]?Window = @splat(null),
    /// Whether keep() hid any window, so an empty plan isn't mistaken for
    /// one without limits.
    hid_some: bool = false,

    /// Hide the kinds of window switched off.
    fn keep(self: *Plan, session: bool, weekly: bool, models: bool) void {
        for (&self.windows) |*slot| {
            const w = slot.* orelse continue;
            const on = switch (w.kind) {
                .session => session,
                .weekly => weekly,
                .model => models,
            };
            if (on) continue;
            slot.* = null;
            self.hid_some = true;
        }
    }
};

pub const Spend = struct {
    cost_usd: f64,
    tokens: u64,
};

pub const Snapshot = struct {
    claude: Plan = .{},
    codex: Plan = .{},
    opencode_found: bool = false,
    opencode_today: ?Spend = null,
    opencode_week: ?Spend = null,
};

/// Which tools to ask and which of their windows to show, from the
/// `ai-usage-*` config keys.
pub const Enabled = packed struct(u16) {
    claude: bool = true,
    claude_session: bool = true,
    claude_weekly: bool = true,
    claude_models: bool = true,
    codex: bool = true,
    codex_session: bool = true,
    codex_weekly: bool = true,
    codex_models: bool = true,
    opencode: bool = true,
    _: u7 = 0,
};

var lock: std.Io.Mutex = .init;
var latest: Snapshot = .{};
var enabled: std.atomic.Value(u16) = .init(@bitCast(Enabled{}));
var started = false;

/// The latest usage, for painting, without the tools switched off.
pub fn snapshot() Snapshot {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    var s = latest;
    const on: Enabled = @bitCast(enabled.load(.acquire));
    if (!on.claude) s.claude = .{};
    if (!on.codex) s.codex = .{};
    if (!on.opencode) s.opencode_found = false;
    s.claude.keep(on.claude_session, on.claude_weekly, on.claude_models);
    s.codex.keep(on.codex_session, on.codex_weekly, on.codex_models);
    return s;
}

/// Follow the config; a tool switched back on shows again at the next read.
pub fn setEnabled(on: Enabled) void {
    enabled.store(@bitCast(on), .release);
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
        const on: Enabled = @bitCast(enabled.load(.acquire));
        var next = blk: {
            lock.lockUncancelable(global.io());
            defer lock.unlock(global.io());
            break :blk latest;
        };
        next.claude.found = on.claude and profiles.programExists("claude.exe");
        if (next.claude.found) readClaude(alloc, &next.claude);
        next.codex.found = on.codex and profiles.programExists("codex.exe");
        if (next.codex.found) readCodex(alloc, &next.codex);
        next.opencode_found = on.opencode and (profiles.programExists("opencode.cmd") or profiles.programExists("opencode.exe"));
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

/// Claude Code's /usage through its control protocol. On any failure the
/// previous windows stay.
fn readClaude(alloc: std.mem.Allocator, into: *Plan) void {
    // The JSON's quotes are escaped: Windows strips bare ones from arguments.
    var cli = HiddenCli.start("claude.exe --output-format stream-json --verbose --input-format stream-json " ++
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
            into.answered = true;
            into.windows = @splat(null);
            const limits = field(usage, "rate_limits") orelse return;
            into.windows[0] = claudeWindow(field(limits, "five_hour"), 5 * 60, .session);
            into.windows[1] = claudeWindow(field(limits, "seven_day"), 7 * 24 * 60, .weekly);
            // Weekly limits of single models, named as Claude Code names
            // them (Fable, ...); new models show up without a change here.
            var n: usize = 2;
            const scoped = field(limits, "model_scoped") orelse return;
            if (scoped != .array) return;
            for (scoped.array.items) |entry| {
                if (n == max_windows) break;
                const name = field(entry, "display_name") orelse continue;
                if (name != .string) continue;
                const w = claudeWindow(entry, 7 * 24 * 60, .model) orelse continue;
                into.windows[n] = w.named(name.string);
                n += 1;
            }
            return;
        }
    }
}

fn claudeWindow(value: ?std.json.Value, minutes: u32, kind: Window.Kind) ?Window {
    const v = value orelse return null;
    const percent = percentOf(field(v, "utilization")) orelse return null;
    const resets_at = if (field(v, "resets_at")) |r| switch (r) {
        .string => |s| parseIso8601(s) orelse 0,
        else => 0,
    } else 0;
    return .{ .percent = percent, .resets_at = resets_at, .minutes = minutes, .kind = kind };
}

/// Codex's ChatGPT plan limits through its app-server's JSON-RPC.
fn readCodex(alloc: std.mem.Allocator, into: *Plan) void {
    var cli = HiddenCli.start("codex.exe app-server") orelse return;
    defer cli.end();
    cli.write("{\"id\":0,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"sharp\",\"title\":\"Sharp\",\"version\":\"0.1.0\"}}}\n");
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);
    while (cli.readLine(alloc, &line_buf)) |line| {
        defer alloc.free(line);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const id = field(parsed.value, "id") orelse continue;
        if (id != .integer) continue;
        if (id.integer == 0) {
            cli.write("{\"method\":\"initialized\"}\n{\"id\":1,\"method\":\"account/rateLimits/read\",\"params\":null}\n");
        } else if (id.integer == 1) {
            const result = field(parsed.value, "result") orelse return;
            const limits = field(result, "rateLimits") orelse return;
            into.answered = true;
            into.windows = @splat(null);
            into.windows[0] = codexWindow(field(limits, "primary"), .session);
            into.windows[1] = codexWindow(field(limits, "secondary"), .weekly);
            // Limits of single models, beside the plan's own ("codex").
            var n: usize = 2;
            const main_id = field(limits, "limitId");
            const by_id = field(result, "rateLimitsByLimitId") orelse return;
            if (by_id != .object) return;
            var it = by_id.object.iterator();
            while (it.next()) |entry| {
                if (n == max_windows) break;
                if (eqlString(main_id, entry.key_ptr.*)) continue;
                const w = codexWindow(field(entry.value_ptr.*, "primary"), .model) orelse
                    codexWindow(field(entry.value_ptr.*, "secondary"), .model) orelse continue;
                const label = field(entry.value_ptr.*, "limitName");
                into.windows[n] = w.named(if (label != null and label.? == .string) label.?.string else entry.key_ptr.*);
                n += 1;
            }
            return;
        }
    }
}

fn codexWindow(value: ?std.json.Value, kind: Window.Kind) ?Window {
    const v = value orelse return null;
    const percent = percentOf(field(v, "usedPercent")) orelse return null;
    return .{
        .percent = percent,
        .resets_at = number(i64, field(v, "resetsAt")),
        .minutes = number(u32, field(v, "windowDurationMins")),
        .kind = kind,
    };
}

fn percentOf(value: ?std.json.Value) ?f32 {
    const percent: f32 = switch (value orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => return null,
    };
    return std.math.clamp(percent, 0, 100);
}

/// OpenCode's spending over the last `days` (0 is today).
fn readOpenCode(alloc: std.mem.Allocator, days: u8) ?Spend {
    var cmd: [96]u8 = undefined;
    // opencode is an npm shim (opencode.cmd), which only cmd.exe can run.
    // --standalone runs a private server that ends with the command, rather
    // than leaving OpenCode's background service started behind.
    const command = std.fmt.bufPrint(&cmd, "cmd.exe /d /c opencode stats --standalone --json --cost --days {d}", .{days}) catch return null;
    var cli = HiddenCli.start(command) orelse return null;
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
        // A value out of range is read as 0, never trusted into a cast.
        .integer => |i| if (T == f64) @floatFromInt(i) else std.math.cast(T, @max(i, 0)) orelse 0,
        .float => |f| if (T == f64) f else std.math.lossyCast(T, @max(f, 0)),
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
