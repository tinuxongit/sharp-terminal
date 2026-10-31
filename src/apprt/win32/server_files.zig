const std = @import("std");
const server_probe = @import("server_probe.zig");
const server_shell = @import("server_shell.zig");
const server_tunnel = @import("server_tunnel.zig");
const tools = @import("server_tools.zig").data;
const Window = @import("Window.zig");

pub const Outcome = enum { opened, sign_in_needed, missing, failed };

const runtime = "\"$HOME/" ++ tools.runtime_folder ++ "\"";
const serve_script =
    "umask 077; d=" ++ runtime ++ "; mkdir -p \"$d\"; chmod 700 \"$d\"; " ++
    "fb=\"" ++ server_probe.files_binary ++ "\"; [ -x \"$fb\" ] || { echo " ++ server_tunnel.missing_marker ++ "; exit 0; }; " ++
    "s=\"$d/files.sock\"; rm -f \"$s\"; " ++
    "\"$fb\" -r / -d \"$d/filebrowser.db\" --noauth --socket \"$s\" --socketPerm 384 >\"$d/filebrowser.log\" 2>&1 & p=$!; " ++
    "i=0; while [ ! -S \"$s\" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; " ++
    "[ -S \"$s\" ] || { cat \"$d/filebrowser.log\"; kill $p; exit 1; }; " ++
    "echo " ++ server_tunnel.ready_marker ++ "; read -r _; kill $p";

pub fn open(self: *Window, destination: []const u8) Outcome {
    const probe = switch (server_probe.read(self.app.core_app.alloc, destination)) {
        .probe => |p| p,
        .sign_in_needed => return .sign_in_needed,
        .unreachable_server => return .failed,
    };
    if (!probe.has_files) return .missing;

    var landing_buf: [server_shell.max_folder_len + 16]u8 = undefined;
    const landing = std.fmt.bufPrint(&landing_buf, "/files{s}/", .{probe.home()}) catch "/";
    if (server_tunnel.running(self, destination, .files)) |port| {
        server_tunnel.show(self, port, landing);
        return .opened;
    }
    var socket_buf: [server_shell.max_folder_len + 64]u8 = undefined;
    const socket = std.fmt.bufPrint(&socket_buf, "{s}/{s}/files.sock", .{ probe.home(), tools.runtime_folder }) catch return .failed;
    return switch (server_tunnel.start(self, destination, .files, socket, serve_script)) {
        .port => |port| {
            server_tunnel.show(self, port, landing);
            return .opened;
        },
        .missing => .missing,
        .sign_in_needed => .sign_in_needed,
        .failed => .failed,
    };
}

pub fn writeInstall(w: *std.Io.Writer) !void {
    const f = tools.files;
    try w.writeAll("case \"$(uname -m)\" in x86_64) u=" ++ f.amd64_url ++ "; h=" ++ f.amd64_sha256 ++ ";; " ++
        "aarch64|arm64) u=" ++ f.arm64_url ++ "; h=" ++ f.arm64_sha256 ++ ";; *) u=;; esac; " ++
        "if [ -z \"$u\" ]; then printf '%s\\n' ");
    try server_shell.writeQuoted(w, f.unsupported);
    try w.writeAll("; else d=\"$HOME/.local/share/sharp/filebrowser-" ++ f.version ++ "\"; " ++
        "mkdir -p \"$d\" && curl -fsSL \"$u\" -o \"$d/fb.tgz\" && echo \"$h  $d/fb.tgz\" | sha256sum -c - && " ++
        "tar -xzf \"$d/fb.tgz\" -C \"$d\" filebrowser && rm -f \"$d/fb.tgz\" && printf '%s\\n' ");
    try server_shell.writeQuoted(w, f.installed);
    try w.writeAll("; fi; ");
}
