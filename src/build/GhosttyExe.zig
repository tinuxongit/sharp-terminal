const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary Ghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        // Sharp only renames the Windows build; other platforms stay as
        // upstream ships them so merges from upstream stay simple.
        .name = if (cfg.target.result.os.tag == .windows) "sharp" else "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            // MinGW's CRT and Windows SEH require unwind metadata even
            // when debug symbols are stripped from a release executable.
            .unwind_tables = if (cfg.target.result.os.tag == .windows)
                .async
            else if (cfg.strip)
                .none
            else
                .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    // Check for possible issues
    try checkNixShell(exe, cfg);

    // Add patchelf step if that option is specified.
    cfg.addPatchElf(exe, &install_step.step);

    // OS-specific
    switch (cfg.target.result.os.tag) {
        .windows => {
            // Subsystem selection:
            // - Debug builds always use Console (visible stderr).
            // - Release builds default to Windows (no console window) but
            //   can opt into Console via -Dwindows-console=true to debug
            //   crashes from end-user reports.
            exe.subsystem = if (cfg.optimize == .debug or cfg.windows_console)
                .console
            else
                .windows;
            // Explorer, the installer and the updater read Sharp's version
            // from the exe's version resource.
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("dist/windows/ghostty.rc"),
                .flags = try sharpVersionDefines(b, cfg.sharp_version),
            });
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// The version resource's defines for `version` ("0.1.1"): the text, and
/// the four numbers Windows wants, the last always 0.
fn sharpVersionDefines(b: *std.Build, version: []const u8) ![]const []const u8 {
    var numbers: [4]u16 = .{ 0, 0, 0, 0 };
    var parts = std.mem.splitScalar(u8, version, '.');
    for (numbers[0..3]) |*n| n.* = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
    return b.allocator.dupe([]const u8, &.{
        b.fmt("/DSHARP_FILEVERSION={d},{d},{d},{d}", .{ numbers[0], numbers[1], numbers[2], numbers[3] }),
        b.fmt("/DSHARP_VERSION_STR=\"{s}\"", .{version}),
    });
}

/// Add the ghostty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);

    const target = self.exe.root_module.resolved_target.?;
    if (target.result.os.tag == .windows) {
        // Copy Microsoft's matching runtime pair; loading it dynamically
        // keeps GNU cross-builds independent of MSVC import libraries.
        const conpty = b.lazyDependency("conpty", .{ .target = target }) orelse return;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            conpty.namedLazyPath("dll"),
            "conpty.dll",
        ).step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            conpty.namedLazyPath("host"),
            "OpenConsole.exe",
        ).step);
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path("dist/windows/conpty-LICENSE.txt"),
            "share/licenses/conpty/LICENSE.txt",
        ).step);
        // Lets Windows hand new consoles to Sharp when it is the default
        // terminal; same project and license as ConPTY. Only x64 is pinned.
        if (target.result.cpu.arch == .x86_64) {
            const wt = b.lazyDependency("windows_terminal", .{}) orelse return;
            b.getInstallStep().dependOn(&b.addInstallBinFile(
                wt.path("terminal-1.24.12741.0/OpenConsoleProxy.dll"),
                "OpenConsoleProxy.dll",
            ).step);
        }
        // MIT requires the copyright notice in every copy of the program.
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path("LICENSE"),
            "share/licenses/sharp/LICENSE.txt",
        ).step);
        // The browser panel's engine: Microsoft's loader for the WebView2
        // runtime Windows ships, loaded by full path like conpty.dll.
        const webview2 = b.lazyDependency("webview2", .{ .target = target }) orelse return;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            webview2.namedLazyPath("loader"),
            "WebView2Loader.dll",
        ).step);
        b.getInstallStep().dependOn(&b.addInstallFile(
            webview2.namedLazyPath("license"),
            "share/licenses/webview2/LICENSE.txt",
        ).step);
        // The AI section's logos come from thesvg.org, under MIT.
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path("dist/windows/logos/LICENSE.txt"),
            "share/licenses/thesvg/LICENSE.txt",
        ).step);
        // The command Claude Code runs to reach the browser panel's tools;
        // it only relays Claude's stdio to Sharp's named pipe.
        const bridge = b.addExecutable(.{
            .name = "sharp-mcp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/win32/mcp_bridge.zig"),
                .target = target,
                .optimize = self.exe.root_module.optimize orelse .ReleaseFast,
                .strip = self.exe.root_module.strip,
            }),
        });
        b.getInstallStep().dependOn(&b.addInstallArtifact(bridge, .{}).step);
    }
}

/// If we're in NixOS but not in the shell environment then we issue
/// a warning because the rpath may not be setup properly. This doesn't modify
/// our build in any way but addresses a common build-from-source issue
/// for a subset of users.
fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    // Non-Linux doesn't have rpath issues.
    if (cfg.target.result.os.tag != .linux) return;

    // When cross-compiling, we don't need to worry about matching our
    // Nix shell rpath since the resulting binary will be run on a
    // separate system.
    if (!cfg.target.query.isNativeCpu()) return;
    if (!cfg.target.query.isNativeOs()) return;

    // Verify we're in NixOS
    std.Io.Dir.accessAbsolute(exe.step.owner.graph.io, "/etc/NIXOS", .{}) catch return;

    // If we're in a nix shell, not a problem
    if (cfg.env.get("IN_NIX_SHELL") != null) return;

    std.log.warn(
        "\x1b[" ++ color_map.get("yellow").? ++
            "\x1b[" ++ color_map.get("d").? ++
            \\Detected building on and for NixOS outside of the Nix shell environment.
            \\
            \\The resulting ghostty binary will likely fail on launch because it is
            \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
            \\We highly recommend running only within the Nix build environment
            \\and the resulting binary will be portable across your system.
            \\
            \\To run in the Nix build environment, use the following command.
            \\Append any additional options like (`-Doptimize` flags). The resulting
            \\binary will be in zig-out as usual.
            \\
            \\  nix develop -c zig build
            \\
        ++
            "\x1b[0m",
        .{},
    );
}

/// ANSI escape codes for colored log output
const color_map = std.StaticStringMap([]const u8).initComptime(.{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
