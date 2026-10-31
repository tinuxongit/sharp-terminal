const std = @import("std");
const global = @import("../../global.zig");
const command_line = @import("command_line.zig");
const profiles = @import("profiles.zig");
const servers = @import("servers.zig");
const server_shell = @import("server_shell.zig");
const ssh_settings = @import("ssh_settings.zig");
const HiddenCli = @import("HiddenCli.zig");
const workspace = @import("workspace.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.server_sign_in);
const text = profiles.data.sidebar.server_menu;
const max_key_len = 1024;

pub fn start(self: *Window, destination: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const settings = ssh_settings.read(alloc, destination) orelse {
        log.warn("ssh -G gave nothing for {s}", .{destination});
        return;
    };
    var key_buf: [max_key_len]u8 = undefined;
    const key = publicKey(alloc, &settings, &key_buf) orelse return;

    var before_buf: [max_key_len * 2 + 512]u8 = undefined;
    var before: std.Io.Writer = .fixed(&before_buf);
    writeInstall(&before, key) catch return;
    _ = workspace.openServerAfter(self, destination, null, before.buffered());
}

fn writeInstall(w: *std.Io.Writer, key: []const u8) !void {
    try w.writeAll("umask 077; mkdir -p ~/.ssh; grep -qxF ");
    try server_shell.writeQuoted(w, key);
    try w.writeAll(" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\\n' ");
    try server_shell.writeQuoted(w, key);
    try w.writeAll(" >> ~/.ssh/authorized_keys; printf '%s\\n' ");
    try server_shell.writeQuoted(w, text.signed_in);
    try w.writeAll("; ");
}

fn publicKey(alloc: std.mem.Allocator, settings: *const ssh_settings.Settings, out: *[max_key_len]u8) ?[]const u8 {
    const files = settings.identityFiles();
    for (files) |*file| {
        if (readPublicKey(alloc, file.text(), out)) |key| return key;
    }
    const target = for (files) |*file| {
        if (std.mem.endsWith(u8, file.text(), "id_ed25519")) break file.text();
    } else if (files.len > 0) files[0].text() else return null;
    if (exists(target)) {
        log.warn("{s} has no readable .pub beside it", .{target});
        return null;
    }
    generate(alloc, target) orelse return null;
    return readPublicKey(alloc, target, out);
}

fn generate(alloc: std.mem.Allocator, private_path: []const u8) ?void {
    var command_buf: [ssh_settings.max_path * 2 + 128]u8 = undefined;
    var command: std.Io.Writer = .fixed(&command_buf);
    command.writeAll("ssh-keygen.exe -q -t ed25519 -N \"\" -C sharp -f ") catch return null;
    command_line.quote(&command, "", private_path) catch return null;
    var cli = HiddenCli.startWithin(command.buffered(), 15_000) orelse return null;
    defer cli.end();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    cli.readAll(alloc, &out);
}

fn readPublicKey(alloc: std.mem.Allocator, private_path: []const u8, out: *[max_key_len]u8) ?[]const u8 {
    var path_buf: [ssh_settings.max_path + 8]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}.pub", .{private_path}) catch return null;
    if (!exists(private_path)) return null;
    const contents = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_key_len)) catch return null;
    defer alloc.free(contents);
    const line = std.mem.trim(u8, contents, " \r\n");
    if (!validKey(line)) return null;
    @memcpy(out[0..line.len], line);
    return out[0..line.len];
}

fn validKey(line: []const u8) bool {
    if (line.len == 0 or line.len > max_key_len) return false;
    if (!std.mem.startsWith(u8, line, "ssh-") and !std.mem.startsWith(u8, line, "ecdsa-") and !std.mem.startsWith(u8, line, "sk-")) return false;
    for (line) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "+/=@._- :", c) != null;
        if (!ok) return false;
    }
    return true;
}

fn exists(path: []const u8) bool {
    return profiles.programExists(path);
}
