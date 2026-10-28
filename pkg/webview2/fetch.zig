const std = @import("std");

// Official Microsoft.Web.WebView2 1.0.4314.35, the SDK whose
// WebView2Loader.dll finds the WebView2 runtime that ships with Windows.
// Pin the complete signed NuGet archive.
const url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4314.35/microsoft.web.webview2.1.0.4314.35.nupkg";
const expected_sha256 = "90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4";
const max_archive_bytes = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2) return error.ExpectedOutputDirectory;

    const buffer = try alloc.alloc(u8, max_archive_bytes);
    var writer: std.Io.Writer = .fixed(buffer);
    var client: std.http.Client = .{ .allocator = alloc, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(alloc, init.environ_map);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
    });
    if (response.status != .ok) {
        std.log.err("downloading the WebView2 SDK failed: HTTP {d}", .{@backingInt(response.status)});
        return error.WebView2DownloadFailed;
    }

    const archive = writer.buffered();
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &hash, .{});
    const actual_sha256 = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, &actual_sha256, expected_sha256)) {
        std.log.err("WebView2 SDK archive SHA256 mismatch: expected {s}, got {s}", .{ expected_sha256, actual_sha256 });
        return error.WebView2HashMismatch;
    }

    // Only verified archive bytes reach the extractor. The build runner
    // publishes the output directory in its cache after this tool succeeds.
    var output = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer output.close(init.io);
    const archive_name = ".webview2-package.zip";
    try output.writeFile(init.io, .{ .sub_path = archive_name, .data = archive });
    defer output.deleteFile(init.io, archive_name) catch {};
    const file = try output.openFile(init.io, archive_name, .{});
    defer file.close(init.io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    try std.zip.extract(output, &reader, .{});
}
