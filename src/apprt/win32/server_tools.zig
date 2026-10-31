const std = @import("std");

pub const Category = struct {
    key: []const u8,
    label: []const u8,
};

pub const Files = struct {
    version: []const u8,
    amd64_url: []const u8,
    amd64_sha256: []const u8,
    arm64_url: []const u8,
    arm64_sha256: []const u8,
    install_title: []const u8,
    install_text: []const u8,
    installed: []const u8,
    unsupported: []const u8,
};

pub const Apps = struct {
    packages: []const u8,
    install_title: []const u8,
    install_text: []const u8,
    installed: []const u8,
    screen: []const u8,
    first_display: u16,
    page: []const u8,
    none: []const u8,
    categories: []const Category,
    other: []const u8,
};

pub const Data = struct {
    tunnel_address: []const u8,
    start_timeout_ms: u32,
    missed_polls_to_end: u8,
    runtime_folder: []const u8,
    files: Files,
    apps: Apps,
    browse_files: []const u8,
    open_app: []const u8,
    failed_title: []const u8,
    failed_text: []const u8,
};

pub const data: Data = @import("server_tools.zon");

fn plainWords(comptime text: []const u8) bool {
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '.' or c == '_' or c == '/' or c == ':')) return false;
    return true;
}

comptime {
    for (.{ data.files.amd64_sha256, data.files.arm64_sha256 }) |hash| {
        if (hash.len != 64) @compileError("server_tools.zon: a sha256 must be 64 hex digits");
        for (hash) |c| if (!std.ascii.isHex(c)) @compileError("server_tools.zon: a sha256 must be hex");
    }
    for (.{ data.files.amd64_url, data.files.arm64_url }) |url| {
        if (!std.mem.startsWith(u8, url, "https://")) @compileError("server_tools.zon: downloads must be https");
    }
    for (.{ data.files.amd64_url, data.files.arm64_url, data.files.version, data.apps.packages, data.apps.screen, data.runtime_folder, data.tunnel_address }) |value| {
        if (!plainWords(value)) @compileError("server_tools.zon: '" ++ value ++ "' goes into a shell command and may hold only letters, digits and - . _ / :");
    }
    if (!std.mem.startsWith(u8, data.tunnel_address, "127.")) @compileError("server_tools.zon: tunnels must listen on loopback");
}
