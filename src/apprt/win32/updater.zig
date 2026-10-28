//! Keeps Sharp up to date, as T3 Code does. A background thread asks
//! GitHub for the newest release shortly after startup and then every few
//! minutes, downloads its installer, and checks it against the release's
//! SHA256SUMS. The tab strip then shows an update button: clicking it
//! restarts into the new version, and otherwise it installs when Sharp
//! quits. Installing runs the NSIS installer silently
//! (dist/windows/installer.nsi). Builds made locally never update.
//! Settings and text: updates.zon.
const std = @import("std");
const build_options = @import("build_options");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const wide_string = @import("wide_string.zig");
const json_read = @import("json_read.zig");
const https = @import("https.zig");
const release_version = @import("release_version.zig");

const Version = release_version.Version;
const windows = internal_os.windows;
const kernel32 = windows.exp.kernel32;
const log = std.log.scoped(.updater);

pub const Data = struct {
    repository: []const u8,
    check_minutes: u32,
    first_check_seconds: u32,
    installer: []const u8,
    checksums: []const u8,
    max_installer_mb: u32,
    restart_title: []const u8,
    restart_prompt: []const u8,
    up_to_date: []const u8,
    downloading: []const u8,
    ready: []const u8,
    dev_build: []const u8,
    check_failed: []const u8,
};

pub const data: Data = @import("updates.zon");

comptime {
    if (std.mem.indexOf(u8, data.installer, "{version}") == null) @compileError("updates.zon: installer must contain {version}");
    if (std.mem.indexOf(u8, data.installer, "{arch}") == null) @compileError("updates.zon: installer must contain {arch}");
    if (data.check_minutes == 0) @compileError("updates.zon: check_minutes must be at least 1");
}

/// The installers' name for this build's processor.
const arch = switch (@import("builtin").cpu.arch) {
    .x86_64 => "x64",
    .aarch64 => "arm64",
    else => @compileError("Sharp is released for x64 and arm64"),
};

/// The running build's version, or null for a local build.
pub fn current() ?Version {
    if (!build_options.sharp_release) return null;
    return Version.parse(build_options.sharp_version);
}

pub const Status = enum { idle, checking, downloading, ready, up_to_date, failed };

pub const Snapshot = struct {
    status: Status = .idle,
    version_buf: [48]u8 = undefined,
    version_len: u8 = 0,
    failure: []const u8 = "",

    pub fn version(self: *const Snapshot) []const u8 {
        return self.version_buf[0..self.version_len];
    }
};

var lock: std.Io.Mutex = .init;
var state: Snapshot = .{};
/// The verified installer, once ready.
var installer_path: [1024:0]u16 = undefined;
/// A check the user asked for, whose result they are told.
var manual = std.atomic.Value(bool).init(false);
var report_due = std.atomic.Value(bool).init(false);
var installing = std.atomic.Value(bool).init(false);
var auto = std.atomic.Value(bool).init(true);
var wake: ?w32.HANDLE = null;
var notify: ?w32.HWND = null;
var notify_message: u32 = 0;

pub fn snapshot() Snapshot {
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    return state;
}

fn set(status: Status, version: ?[]const u8, failure: []const u8) void {
    {
        lock.lockUncancelable(global.io());
        defer lock.unlock(global.io());
        state.status = status;
        state.failure = failure;
        if (version) |v| {
            const n: u8 = @intCast(@min(v.len, state.version_buf.len));
            @memcpy(state.version_buf[0..n], v[0..n]);
            state.version_len = n;
        }
    }
    if (notify) |hwnd| _ = w32.PostMessageW(hwnd, notify_message, 0, 0);
}

/// Follow Settings > General > Updates. Starts the thread the first time,
/// once the app's message window exists; `message` is posted to it after
/// every change.
pub fn configure(hwnd: w32.HWND, message: u32, automatic: bool) void {
    if (current() == null) return;
    const changed = auto.swap(automatic, .acq_rel) != automatic and automatic;
    if (wake == null) {
        notify = hwnd;
        notify_message = message;
        wake = w32.CreateEventW(null, 0, 0, null) orelse return;
        const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
            log.warn("failed to start the updater: {}", .{err});
            return;
        };
        thread.detach();
    } else if (changed) {
        _ = w32.SetEvent(wake.?);
    }
}

/// Check now and tell the user what came of it (takeReport).
pub fn checkNow() void {
    if (current() == null) {
        report_due.store(true, .release);
        if (notify) |hwnd| _ = w32.PostMessageW(hwnd, notify_message, 0, 0);
        return;
    }
    manual.store(true, .release);
    if (wake) |event| _ = w32.SetEvent(event);
}

/// The text to show for a check the user asked for, once it finished.
pub fn takeReport(out: []u8) ?[]const u8 {
    if (!report_due.swap(false, .acq_rel)) return null;
    if (current() == null) return data.dev_build;
    const s = snapshot();
    const own = build_options.sharp_version;
    const text, const version = switch (s.status) {
        .ready => .{ data.ready, s.version() },
        .downloading => .{ data.downloading, s.version() },
        .failed => .{ data.check_failed, s.failure },
        else => .{ data.up_to_date, own },
    };
    return fill(out[0 .. out.len / 2], text, version);
}

fn fill(out: []u8, template: []const u8, value: []const u8) []const u8 {
    const placeholder = if (std.mem.indexOf(u8, template, "{version}") != null) "{version}" else "{error}";
    const at = std.mem.indexOf(u8, template, placeholder) orelse return template;
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ template[0..at], value, template[at + placeholder.len ..] }) catch template;
}

/// The prompt before restarting into the ready update.
pub fn restartPrompt(out: []u8) []const u8 {
    const s = snapshot();
    return fill(out, data.restart_prompt, s.version());
}

fn run() void {
    _ = w32.WaitForSingleObject(wake.?, data.first_check_seconds * 1000);
    while (true) {
        const asked = manual.swap(false, .acq_rel);
        if (asked or auto.load(.acquire)) {
            check();
            if (asked) report_due.store(true, .release);
            if (notify) |hwnd| _ = w32.PostMessageW(hwnd, notify_message, 0, 0);
        }
        _ = w32.WaitForSingleObject(wake.?, data.check_minutes * 60 * 1000);
    }
}

fn check() void {
    const alloc = std.heap.smp_allocator;
    const own = current() orelse return;
    if (snapshot().status == .ready) return;
    set(.checking, null, "");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const found = newest(a) catch |err| return set(.failed, null, @errorName(err));
    const release = found orelse return set(.up_to_date, null, "");
    if (release.version.order(own) != .gt) return set(.up_to_date, null, "");

    set(.downloading, release.tag[1..], "");
    download(a, release) catch |err| {
        log.warn("update download failed: {}", .{err});
        return set(.failed, release.tag[1..], @errorName(err));
    };
    set(.ready, release.tag[1..], "");
}

const Release = struct {
    tag: []const u8,
    version: Version,
    installer_url: []const u8,
    installer_name: []const u8,
    checksums_url: []const u8,
};

/// The newest published release that has an installer.
fn newest(a: std.mem.Allocator) !?Release {
    const url = try std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/releases?per_page=30", .{data.repository});
    const body = try https.get(a, url, "application/vnd.github+json", 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    if (parsed != .array) return error.UnexpectedAnswer;
    var best: ?Release = null;
    for (parsed.array.items) |item| {
        if (json_read.boolean(item, "draft") orelse true) continue;
        const tag = json_read.string(item, "tag_name") orelse continue;
        if (tag.len < 2 or tag[0] != 'v') continue;
        const version = Version.parse(tag[1..]) orelse continue;
        // A prerelease is a test, not a release.
        if (json_read.boolean(item, "prerelease") orelse true) continue;
        if (best) |b| if (version.order(b.version) != .gt) continue;
        const versioned = try std.mem.replaceOwned(u8, a, data.installer, "{version}", tag[1..]);
        const installer_name = try std.mem.replaceOwned(u8, a, versioned, "{arch}", arch);
        var installer_url: ?[]const u8 = null;
        var checksums_url: ?[]const u8 = null;
        const assets = json_read.field(item, "assets") orelse continue;
        if (assets != .array) continue;
        for (assets.array.items) |asset| {
            const name = json_read.string(asset, "name") orelse continue;
            const link = json_read.string(asset, "browser_download_url") orelse continue;
            if (std.mem.eql(u8, name, installer_name)) installer_url = link;
            if (std.mem.eql(u8, name, data.checksums)) checksums_url = link;
        }
        best = .{
            .tag = tag,
            .version = version,
            .installer_url = installer_url orelse continue,
            .installer_name = installer_name,
            .checksums_url = checksums_url orelse continue,
        };
    }
    return best;
}

/// Fetch the release's installer into %LOCALAPPDATA%\Sharp\Updates and
/// check it against SHA256SUMS; an earlier, verified download is reused.
fn download(a: std.mem.Allocator, release: Release) !void {
    const sums = try https.get(a, release.checksums_url, null, 64 * 1024);
    const expected = expectedHash(sums, release.installer_name) orelse return error.NotInChecksums;

    var dir_buf: [1024]u8 = undefined;
    const dir = updatesDir(&dir_buf) orelse return error.NoLocalAppData;
    const path = try std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, release.installer_name });
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    if (path_w.len >= installer_path.len) return error.NameTooLong;

    const max = @as(usize, data.max_installer_mb) << 20;
    const existing = std.Io.Dir.cwd().readFileAlloc(global.io(), path, a, .limited(max)) catch null;
    if (existing == null or !matches(existing.?, expected)) {
        const got = try https.get(a, release.installer_url, "application/octet-stream", max);
        if (!matches(got, expected)) return error.ChecksumMismatch;
        // Written beside it and moved into place, so it is never half there.
        const temp = try std.fmt.allocPrint(a, "{s}.part", .{path});
        try std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = temp, .data = got });
        const temp_w = try std.unicode.utf8ToUtf16LeAllocZ(a, temp);
        if (w32.MoveFileExW(temp_w, path_w, w32.MOVEFILE_REPLACE_EXISTING) == 0) return error.MoveFailed;
    }
    lock.lockUncancelable(global.io());
    defer lock.unlock(global.io());
    @memcpy(installer_path[0..path_w.len], path_w);
    installer_path[path_w.len] = 0;
}

fn expectedHash(sums: []const u8, name: []const u8) ?[32]u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const file = std.mem.trimStart(u8, std.mem.trimStart(u8, line[space..], " \t"), "*");
        if (!std.mem.eql(u8, file, name) or space != 64) continue;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, line[0..64]) catch return null;
        return hash;
    }
    return null;
}

fn matches(bytes: []const u8, expected: [32]u8) bool {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.crypto.timing_safe.eql([32]u8, actual, expected);
}

fn updatesDir(out: []u8) ?[]const u8 {
    var wide: [512]u16 = undefined;
    const len = w32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &wide, wide.len);
    if (len == 0 or len >= wide.len) return null;
    const base = wide_string.toUtf8(out, wide[0..len]);
    const dir = std.fmt.bufPrint(out[base..], "\\" ++ brand.name ++ "\\Updates", .{}) catch return null;
    const full = out[0 .. base + dir.len];
    std.Io.Dir.cwd().createDirPath(global.io(), full) catch return null;
    return full;
}

/// Run the ready installer, silently, once Sharp has quit; with `relaunch`
/// it starts Sharp again afterwards. False when no update is ready.
pub fn install(relaunch: bool) bool {
    if (snapshot().status != .ready or installing.swap(true, .acq_rel)) return false;
    var line_buf: [1100:0]u16 = undefined;
    const path = blk: {
        lock.lockUncancelable(global.io());
        defer lock.unlock(global.io());
        break :blk std.mem.sliceTo(&installer_path, 0);
    };
    const args = if (relaunch) std.unicode.utf8ToUtf16LeStringLiteral(" /S /relaunch") else std.unicode.utf8ToUtf16LeStringLiteral(" /S");
    if (path.len + args.len + 3 > line_buf.len) return false;
    line_buf[0] = '"';
    @memcpy(line_buf[1..][0..path.len], path);
    line_buf[1 + path.len] = '"';
    @memcpy(line_buf[2 + path.len ..][0..args.len], args);
    line_buf[2 + path.len + args.len] = 0;

    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var info: windows.PROCESS_INFORMATION = undefined;
    const detached = 0x00000008;
    if (kernel32.CreateProcessW(null, &line_buf, null, null, windows.FALSE, detached, null, null, &startup, &info) == windows.FALSE) {
        installing.store(false, .release);
        log.warn("could not start the update installer", .{});
        return false;
    }
    _ = kernel32.CloseHandle(info.hThread);
    _ = kernel32.CloseHandle(info.hProcess);
    return true;
}

/// When Sharp quits with an update ready and updating automatically, it
/// installs then, as electron-updater's autoInstallOnAppQuit does.
pub fn installOnQuit() void {
    if (auto.load(.acquire)) _ = install(false);
}
