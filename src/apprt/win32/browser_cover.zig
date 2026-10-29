const std = @import("std");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "BrowserCover");
var class_atom: u16 = 0;
const capture_blt: u32 = 0x40000000;

pub const Cover = struct {
    hwnd: ?w32.HWND = null,
    bitmap: ?*anyopaque = null,

    pub fn show(self: *Cover, instance: w32.HINSTANCE, parent: w32.HWND, rect: w32.RECT) void {
        self.hide();
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width <= 0 or height <= 0) return;
        if (!registered(instance)) return;
        var corner: w32.POINT = .{ .x = rect.left, .y = rect.top };
        if (w32.ClientToScreen(parent, &corner) == 0) return;
        const screen = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen);
        const memory = w32.CreateCompatibleDC(screen) orelse return;
        defer _ = w32.DeleteDC(memory);
        const bitmap = w32.CreateCompatibleBitmap(screen, width, height) orelse return;
        const old = w32.SelectObject(memory, bitmap);
        _ = w32.BitBlt(memory, 0, 0, width, height, screen, corner.x, corner.y, w32.SRCCOPY | capture_blt);
        _ = w32.SelectObject(memory, old);
        self.bitmap = bitmap;
        self.hwnd = w32.CreateWindowExW(0, class_name, std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_CHILD | w32.WS_VISIBLE_STYLE, rect.left, rect.top, width, height, parent, null, instance, null);
        const hwnd = self.hwnd orelse return self.hide();
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(bitmap)));
        _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
        _ = w32.UpdateWindow(hwnd);
    }

    pub fn hide(self: *Cover) void {
        if (self.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
        if (self.bitmap) |bitmap| _ = w32.DeleteObject(bitmap);
        self.* = .{};
    }
};

fn registered(instance: w32.HINSTANCE) bool {
    if (class_atom != 0) return true;
    class_atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    return class_atom != 0;
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            const bitmap: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA))));
            const memory = w32.CreateCompatibleDC(hdc) orelse return 0;
            defer _ = w32.DeleteDC(memory);
            const old = w32.SelectObject(memory, bitmap);
            defer _ = w32.SelectObject(memory, old);
            var client: w32.RECT = undefined;
            _ = w32.GetClientRect(hwnd, &client);
            _ = w32.BitBlt(hdc, 0, 0, client.right, client.bottom, memory, 0, 0, w32.SRCCOPY);
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_NCHITTEST => return -1,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
