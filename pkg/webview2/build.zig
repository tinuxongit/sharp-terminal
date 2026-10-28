const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const arch = switch (target.result.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => @panic("WebView2 is available only for x86, x86_64, and aarch64 Windows targets"),
    };

    // NuGet serves application/octet-stream with a .nupkg filename, which
    // Zig's package fetcher cannot identify as ZIP. This native build tool
    // verifies the pinned archive before extracting it, without MSVC tools.
    const helper = b.addExecutable(.{
        .name = "fetch-webview2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fetch.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const fetch = b.addRunArtifact(helper);
    const package = fetch.addOutputDirectoryArg("package");
    // Declaring the extracted directory as a run output caches the download
    // across builds. Changing the pinned URL/hash in fetch.zig invalidates it.
    b.addNamedLazyPath("loader", package.path(b, b.fmt("build/native/{s}/WebView2Loader.dll", .{arch})));
    b.addNamedLazyPath("license", package.path(b, "LICENSE.txt"));
    b.getInstallStep().dependOn(&fetch.step);
}
