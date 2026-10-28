//! Writes RGBA images as PNG files, which Ghostty can draw as its
//! background image.
const std = @import("std");
const flate = std.compress.flate;

/// Encode `rgba` (width × height pixels, 4 bytes each, rows top down).
/// The caller frees the result.
pub fn encode(alloc: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    // Each row starts with its filter byte: 0, none.
    const row = @as(usize, width) * 4;
    const raw = try alloc.alloc(u8, (row + 1) * height);
    defer alloc.free(raw);
    for (0..height) |y| {
        raw[y * (row + 1)] = 0;
        @memcpy(raw[y * (row + 1) + 1 ..][0..row], rgba[y * row ..][0..row]);
    }
    var compressed: std.Io.Writer.Allocating = try .initCapacity(alloc, 64 * 1024);
    defer compressed.deinit();
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var zlib: flate.Compress = try .init(&compressed.writer, window, .zlib, .default);
    try zlib.writer.writeAll(raw);
    try zlib.finish();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    // 8 bits per channel, RGBA, deflate, filtered per row, not interlaced.
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &header);
    try chunk(w, "IDAT", compressed.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}
