//! HTTPS GETs through WinHTTP, Windows' own client, so the system's proxy
//! settings and certificate store apply. Redirects (GitHub sends release
//! downloads elsewhere) are followed, never from HTTPS to HTTP.
const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");

pub const Error = error{ BadUrl, Connect, Request, Status, TooBig, OutOfMemory };

/// GET `url` (https only) into memory, at most `max` bytes. `accept` is
/// sent as the Accept header when given. The caller frees the result.
pub fn get(alloc: std.mem.Allocator, url: []const u8, accept: ?[]const u8, max: usize) Error![]u8 {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.BadUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    if (host.len == 0 or std.mem.indexOfAny(u8, host, ":@") != null) return error.BadUrl;

    const host_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, host) catch return error.OutOfMemory;
    defer alloc.free(host_w);
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return error.OutOfMemory;
    defer alloc.free(path_w);

    const session = w32.WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "-updater"), w32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
        return error.Connect;
    defer _ = w32.WinHttpCloseHandle(session);
    _ = w32.WinHttpSetTimeouts(session, 15_000, 15_000, 30_000, 60_000);
    const connection = w32.WinHttpConnect(session, host_w, 443, 0) orelse return error.Connect;
    defer _ = w32.WinHttpCloseHandle(connection);
    const request = w32.WinHttpOpenRequest(connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), path_w, null, null, null, w32.WINHTTP_FLAG_SECURE) orelse
        return error.Request;
    defer _ = w32.WinHttpCloseHandle(request);

    var headers: ?[:0]u16 = null;
    defer if (headers) |h| alloc.free(h);
    if (accept) |a| {
        const text = std.fmt.allocPrint(alloc, "Accept: {s}\r\n", .{a}) catch return error.OutOfMemory;
        defer alloc.free(text);
        headers = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return error.OutOfMemory;
    }
    const header_ptr: ?[*]const u16 = if (headers) |h| h.ptr else null;
    const header_len: u32 = if (headers) |h| @intCast(h.len) else 0;
    if (w32.WinHttpSendRequest(request, header_ptr, header_len, null, 0, 0, 0) == 0) return error.Request;
    if (w32.WinHttpReceiveResponse(request, null) == 0) return error.Request;

    var status: u32 = 0;
    var status_len: u32 = @sizeOf(u32);
    if (w32.WinHttpQueryHeaders(request, w32.WINHTTP_QUERY_STATUS_CODE | w32.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_len, null) == 0) return error.Request;
    if (status != 200) return error.Status;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (w32.WinHttpReadData(request, &chunk, chunk.len, &got) == 0) return error.Request;
        if (got == 0) break;
        if (body.items.len + got > max) return error.TooBig;
        body.appendSlice(alloc, chunk[0..got]) catch return error.OutOfMemory;
    }
    return body.toOwnedSlice(alloc) catch error.OutOfMemory;
}
