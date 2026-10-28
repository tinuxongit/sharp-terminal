//! Finds the server an SSH session in a tab is connected to, so the tab
//! sidebar can list the tab under Servers. Windows sends no notice when a
//! shell starts ssh, so Window polls: the shell's process tree (from
//! process_tree.zig) is searched
//! for an SSH client (OpenSSH's ssh.exe, PuTTY's plink.exe, or wsl.exe
//! running ssh) and its command line read for the destination.
const std = @import("std");
const process_tree = @import("process_tree.zig");

/// Where the shell `shell_pid` is connected to through ssh ("user@host"
/// or "host"), written into `out`, or null when it isn't running ssh.
/// A tab opened on a server runs ssh as its shell.
pub fn host(procs: *const process_tree.Processes, shell_pid: u32, out: []u8) ?[]const u8 {
    var found: [16]process_tree.Process = undefined;
    for (procs.below(shell_pid, &found)) |p| {
        if (p.program != .ssh and p.program != .plink and p.program != .wsl) continue;
        var line: [2048]u8 = undefined;
        const command_line = process_tree.commandLine(p.pid, &line) orelse continue;
        var dest_buf: [256]u8 = undefined;
        const destination = switch (p.program) {
            .ssh => parseDestination(command_line, &dest_buf),
            .plink => parsePlink(command_line, &dest_buf),
            .wsl => parseWsl(command_line, &dest_buf),
            else => unreachable,
        } orelse continue;
        const len = @min(destination.len, out.len);
        @memcpy(out[0..len], destination[0..len]);
        return out[0..len];
    }
    return null;
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
