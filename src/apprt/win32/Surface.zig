//! Win32 Surface. Each Surface corresponds to one HWND (window) and
//! owns an OpenGL (WGL) context for rendering.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const termio = @import("../../termio.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const servers = @import("servers.zig");
const claude_session = @import("claude_session.zig");
const frame_log = @import("frame_log.zig");
const FramePacer = @import("frame_pacer.zig");
const Scrollbar = @import("Scrollbar.zig").Scrollbar;
const find_bar = @import("find_bar.zig");
const command_palette = @import("command_palette.zig");
const ime = @import("ime.zig");
const clipboard = @import("clipboard.zig");
const win32_input = @import("win32_input.zig");
const key_map = @import("key_map.zig");

const log = std.log.scoped(.win32);

/// The Win32 window handle.
hwnd: ?w32.HWND = null,

/// Device context for the window (with CS_OWNDC, this persists for the
/// lifetime of the window).
hdc: ?w32.HDC = null,

/// WGL OpenGL rendering context.
hglrc: ?w32.HGLRC = null,

/// Current client area dimensions in pixels.
width: u32 = 800,
height: u32 = 600,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// The parent App.
app: *App,

/// The parent Window that contains this Surface as a tab.
parent_window: *Window = undefined,

/// The shell profile's icon shown on this surface's tab, owned by App.
icon: ?w32.HICON = null,

/// What the tab sidebar shows about this surface: where its shell runs,
/// its folder (from OSC 7, when the shell reports it), when it opened and
/// whether it rang the bell while out of sight.
profile_name: [64]u8 = undefined,
profile_name_len: u8 = 0,
wsl: bool = false,
folder: [260]u8 = undefined,
folder_len: u16 = 0,
/// The SSH server this pane is connected to, found by Window's polling.
ssh_host: [128]u8 = undefined,
ssh_host_len: u8 = 0,
/// The Claude Code conversation running here, found the same way.
claude: ?claude_session.Session = null,
opened_ms: u64 = 0,
attention: bool = false,

/// Last title reported by the core for getTitle/copy-title consumers.
title_len: usize = 0,
title: [4096]u8 = std.mem.zeroes([4096]u8),

/// The core terminal surface. Initialized by init() after creating
/// the window and WGL context. Manages fonts, renderer, PTY, and IO.
core_surface: CoreSurface = undefined,

/// Whether core_surface has been fully initialized. Win32 messages
/// (WM_SETFOCUS, WM_SIZE, etc.) can arrive during init before
/// core_surface is ready — handlers must check this flag.
core_surface_ready: bool = false,

/// Whether core_surface.init() completed successfully (ever).
/// Different from core_surface_ready which is cleared during shutdown.
core_surface_initialized: bool = false,

/// Buffered high surrogate from WM_CHAR for supplementary plane characters.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages (surrogate pair).
high_surrogate: u16 = 0,

/// Bitmask of currently-pressed mouse buttons (left=1, right=2,
/// middle=4). Used so SetCapture/ReleaseCapture only run on the
/// 0→nonzero and nonzero→0 transitions; without this, a right-click
/// in the middle of a left-button drag would call SetCapture again
/// (replacing capture) and the next button-up would release prematurely.
mouse_button_mask: u3 = 0,

/// Whether an IME composition session is active. When true, handleKeyEvent
/// skips VK_PROCESSKEY events (the IME is intercepting keys), and composed
/// text is extracted from WM_IME_COMPOSITION instead.
ime_composing: bool = false,

/// Set to true when handleKeyEvent produced text via ToUnicode. Any
/// subsequent WM_CHAR (from IME, SendInput Unicode/VK_PACKET, or
/// PostMessage) is then suppressed to avoid double input. Reset to false
/// when WM_CHAR arrives (whether suppressed or processed).
key_event_produced_text: bool = false,

/// Manual-reset event signaled by the renderer thread after presenting
/// a frame. The main thread waits on this during live resize to
/// synchronize rendering with the DWM compositor.
frame_event: ?w32.HANDLE = null,

/// Paces the renderer thread to the display; only that thread uses it.
frame_pacer: FramePacer = .{},

/// Themed scrollbar (custom layered-popup overlay).
/// Created lazily after the surface HWND exists.
scrollbar: ?*Scrollbar = null,

/// The current mouse cursor. Cached so WM_SETCURSOR can restore it
/// (DefWindowProc resets the cursor to the class cursor on every
/// WM_SETCURSOR, so we must override it ourselves).
current_cursor: ?w32.HCURSOR = null,

/// When false, WM_SETCURSOR sets the cursor to null (invisible). The
/// core surface toggles this for typing-while-mouse-still etc.
mouse_visible: bool = true,

/// Search popup HWND (a small top-level window containing an Edit
/// control). Uses a popup instead of a child window because the
/// OpenGL viewport covers the entire client area and would paint
/// over a child control.
search_hwnd: ?w32.HWND = null,

/// The Edit control inside the search popup.
search_edit: ?w32.HWND = null,

/// Whether the search bar is currently visible.
search_active: bool = false,

/// Font handle for the search edit (must be deleted on cleanup).
search_font: ?*anyopaque = null,

/// Right-aligned STATIC control in the search popup showing the
/// "selected/total" match count (search_total / search_selected actions).
search_count_label: ?w32.HWND = null,

/// Small popup at the bottom-left of the surface showing the hovered URL
/// (mouse_over_link action), like a browser status bubble.
link_preview_hwnd: ?w32.HWND = null,

/// Font for the link preview popup (deleted on cleanup).
link_font: ?*anyopaque = null,

/// Last reported search match count and selected index (0-based), from
/// the search_total / search_selected apprt actions.
search_total: ?usize = null,
search_selected: ?usize = null,

/// Last visibility state DELIVERED to the core occlusionCallback, so
/// setVisible can drop redundant updates on the producer side. This must
/// happen here: occlusionCallback pushes into the renderer mailbox with
/// a bounded timeout, and the consumer-side dedupe in the renderer
/// thread never runs while that mailbox is undrained, so repeated
/// identical pushes (e.g. layoutSplits on every WM_SIZE of a resize
/// drag) would stall the GUI thread and drop. Reset to null when
/// delivery fails so the next call retries.
last_reported_visible: ?bool = null,

/// Command palette popup HWND.
palette_hwnd: ?w32.HWND = null,
/// Edit control inside the command palette popup.
palette_edit: ?w32.HWND = null,
/// Font handle for the palette edit (must be deleted on cleanup).
palette_font: ?*anyopaque = null,
/// Cached paint-time font for the palette list (14pt Segoe UI). The
/// edit control uses palette_font (16pt); this is for FillRect/DrawText
/// in paintPalette. Cached so we don't allocate a new HFONT on every
/// keystroke-driven repaint.
palette_paint_font: ?*anyopaque = null,
/// Cached brush for palette background (reused in WM_CTLCOLOREDIT).
palette_brush: ?w32.HBRUSH = null,
/// Whether the command palette is currently visible.
palette_active: bool = false,
/// Currently selected item in the filtered palette list.
palette_selected: u16 = 0,
/// Number of items currently in the filtered list.
palette_count: u16 = 0,
/// Indices into palette_entries for the current filter.
palette_filtered: [command_palette.palette_entries.len + command_palette.MAX_USER_PALETTE_ENTRIES]u16 = undefined,

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// SplitTree view protocol: decrement reference count.
pub fn unref(self: *Surface, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        self.deinit();
        alloc.destroy(self);
    }
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}

/// Initialize a new Surface by creating a Win32 window and WGL context,
/// then initialize the core terminal surface (fonts, renderer, PTY, IO).
pub fn init(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    return self.initWithOptions(app, parent, .{ .context = context });
}

pub const InitOptions = struct {
    context: apprt.surface.NewSurfaceContext,
    command: ?*const configpkg.Command = null,
    title: ?[:0]const u8 = null,
    /// The shell profile's icon, owned by App's icon cache.
    icon: ?w32.HICON = null,
    /// The shell profile's name, copied: the sidebar's fallback group.
    profile_name: []const u8 = "",
    /// Whether the shell runs in WSL, for the sidebar's sections.
    wsl: bool = false,
    /// Start in this folder instead of the inherited or configured one.
    working_directory: ?[]const u8 = null,
};

/// Initialize a surface with optional per-surface config overrides. The
/// overrides are cloned into the surface config arena before this function
/// returns, so callers only need to keep them alive for the duration of init.
pub fn initWithOptions(
    self: *Surface,
    app: *App,
    parent: *Window,
    options: InitOptions,
) !void {
    self.* = .{
        .app = app,
        .parent_window = parent,
        .icon = options.icon,
        .wsl = options.wsl,
        .opened_ms = w32.GetTickCount64(),
    };
    self.profile_name_len = @intCast(@min(options.profile_name.len, self.profile_name.len));
    @memcpy(self.profile_name[0..self.profile_name_len], options.profile_name[0..self.profile_name_len]);

    // Create a manual-reset event for synchronizing resize with the
    // renderer thread. Manual-reset so we control exactly when it's reset.
    self.frame_event = w32.CreateEventW(null, 1, 0, null);

    // Create a WS_CHILD window inside the parent Window container.
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;
    const sr = parent.surfaceRect();
    const hwnd = w32.CreateWindowExW(
        0,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Accept dropped files so a file dragged onto the terminal pastes
    // its path. WM_DROPFILES is delivered to surfaceWndProc.
    w32.DragAcceptFiles(hwnd, 1);

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;
    errdefer {
        _ = w32.ReleaseDC(hwnd, self.hdc.?);
        self.hdc = null;
    }

    // Set up the pixel format for OpenGL
    try self.setupPixelFormat();

    // Create the WGL context
    self.hglrc = w32.wglCreateContext(self.hdc.?);
    if (self.hglrc == null) return error.Win32Error;
    errdefer {
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(self.hglrc.?);
        self.hglrc = null;
    }

    if (w32.wglMakeCurrent(self.hdc.?, self.hglrc.?) != 0) {
        disableSwapWait();
        _ = w32.wglMakeCurrent(null, null);
    }

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    // Show the child window before initializing the core surface.
    // core_surface.init() spawns ConPTY + cmd.exe which needs the
    // window to be visible and have valid dimensions. On the old
    // top-level architecture, ShowWindow was called in createWindow()
    // before core_surface.init(). We must preserve that order.
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    // --- Core terminal surface initialization ---
    const alloc = app.core_app.alloc;

    // Create the themed scrollbar popup (owned by the surface HWND).
    self.scrollbar = try Scrollbar.create(alloc, hwnd, self);
    errdefer if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    };

    // Seed initial theme colors from the app config.
    if (self.scrollbar) |sb| {
        sb.setTheme(
            app.config.background.toTerminalRGB(),
            app.config.foreground.toTerminalRGB(),
        );
    }

    // Register this surface with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Create a config copy for this surface.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, options.context);
    defer config.deinit();

    if (options.command) |command| {
        config.command = try command.clone(config.arenaAlloc());
        config.@"shell-integration" = .detect;
    }
    if (options.title) |title| {
        config.title = try config.arenaAlloc().dupeSentinel(u8, title, 0);
    }
    if (options.working_directory) |dir| {
        config.@"working-directory" = .{ .path = try config.arenaAlloc().dupe(u8, dir) };
    }

    // The sidebar groups tabs by folder from the start; the shell's own
    // reports (OSC 7) keep it current afterwards.
    if (config.@"working-directory") |dir| switch (dir) {
        .path => |path| _ = self.setFolder(path),
        .home, .inherit => self.setHomeFolder(),
    } else self.setHomeFolder();

    // Initialize the core surface. This sets up fonts, the renderer, PTY,
    // and spawns the renderer + IO threads.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );

    // Mark the surface as ready. Before this point, Win32 messages
    // (triggered by ShowWindow, wglCreateContext, etc.) must be ignored.
    self.core_surface_ready = true;
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Surface) void {
    log.debug("surface deinit: start addr={x}", .{@intFromPtr(self)});

    if (self.core_surface_initialized) {
        log.debug("surface deinit: core_surface.deinit start", .{});
        self.core_surface.deinit();
        log.debug("surface deinit: core_surface.deinit done", .{});

        self.app.core_app.deleteSurface(self);
        log.debug("surface deinit: deleteSurface done", .{});
    }

    // The renderer thread, its only user, has been joined.
    self.frame_pacer.deinit();
    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }
    log.debug("surface deinit: frame_event closed", .{});

    if (self.hglrc) |hglrc| {
        log.debug("surface deinit: wglMakeCurrent(null)", .{});
        _ = w32.wglMakeCurrent(null, null);
        log.debug("surface deinit: wglDeleteContext", .{});
        _ = w32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }
    log.debug("surface deinit: GL context cleaned up", .{});

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            log.debug("surface deinit: ReleaseDC", .{});
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }
    log.debug("surface deinit: DC released", .{});

    self.deinitGui();
}

/// Destroy resources only the GUI thread touches: the scrollbar, popup
/// windows, GDI objects, and the GWLP_USERDATA back-pointer. Called on
/// both the normal deinit path and the leak path (wedged surface thread),
/// where everything the renderer/IO threads can reach must stay alive.
fn deinitGui(self: *Surface) void {
    // Destroy the themed scrollbar before the surface HWND is gone.
    if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    }

    // Destroy popup windows and their GDI resources.
    if (self.search_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.search_hwnd = null;
        self.search_edit = null;
        self.search_count_label = null;
    }
    if (self.search_font) |f| {
        _ = w32.DeleteObject(f);
        self.search_font = null;
    }
    if (self.link_preview_hwnd) |h| {
        _ = w32.DestroyWindow(h);
        self.link_preview_hwnd = null;
    }
    if (self.link_font) |f| {
        _ = w32.DeleteObject(f);
        self.link_font = null;
    }
    if (self.palette_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.palette_hwnd = null;
        self.palette_edit = null;
    }
    if (self.palette_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_font = null;
    }
    if (self.palette_brush) |b| {
        _ = w32.DeleteObject(b);
        self.palette_brush = null;
    }
    if (self.palette_paint_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_paint_font = null;
    }

    // Don't call DestroyWindow on the child HWND here. The OPENGL32.dll
    // driver hooks into window destruction and segfaults after we've already
    // cleaned up the WGL context. The child HWND will be automatically
    // destroyed when the parent Window HWND is destroyed by Win32.
    // Just null the hwnd field so nothing else tries to use it.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    }
    self.hwnd = null;
    log.debug("surface deinit: complete", .{});
}

/// Move the terminal child and its top-level popups together. Each popup has
/// a non-null owner, so a zero previous owner from SetWindowLongPtrW means
/// the transfer failed. Restore every completed change before returning.
pub fn reparentNativeWindows(self: *Surface, parent: w32.HWND) !void {
    const hwnd = self.hwnd orelse return;
    const previous_parent = w32.SetParent(hwnd, parent) orelse return error.Win32Error;
    errdefer _ = w32.SetParent(hwnd, previous_parent);

    const popups = [_]?w32.HWND{ self.search_hwnd, self.palette_hwnd, self.link_preview_hwnd };
    var previous_owners: [popups.len]isize = @splat(0);
    errdefer for (popups, previous_owners) |popup, owner| {
        if (owner != 0) _ = w32.SetWindowLongPtrW(popup.?, w32.GWLP_HWNDPARENT, owner);
    };
    for (popups, 0..) |popup, i| {
        const h = popup orelse continue;
        const owner = w32.SetWindowLongPtrW(h, w32.GWLP_HWNDPARENT, @bitCast(@intFromPtr(parent)));
        if (owner == 0) return error.Win32Error;
        previous_owners[i] = owner;
    }
}

/// A popup can be destroyed without destroying its terminal surface.
pub fn popupDestroyed(self: *Surface, hwnd: w32.HWND) void {
    if (self.search_hwnd == hwnd) {
        self.search_hwnd = null;
        self.search_edit = null;
        self.search_count_label = null;
        self.search_active = false;
        self.search_total = null;
        self.search_selected = null;
        if (self.search_font) |font| _ = w32.DeleteObject(font);
        self.search_font = null;
    } else if (self.palette_hwnd == hwnd) {
        self.palette_hwnd = null;
        self.palette_edit = null;
        self.palette_active = false;
        if (self.palette_font) |font| _ = w32.DeleteObject(font);
        self.palette_font = null;
        if (self.palette_paint_font) |font| _ = w32.DeleteObject(font);
        self.palette_paint_font = null;
        if (self.palette_brush) |brush| _ = w32.DeleteObject(brush);
        self.palette_brush = null;
    }
}

/// WGL contexts are per-surface; the shared renderer device has no options.
pub fn renderDeviceOptions(_: *Surface) !@import("../../renderer.zig").Device.Options {
    return .{};
}

/// Recreate the WGL context after GPU context loss (driver reset/TDR)
/// and make it current. Renderer-thread only: the GUI thread touches
/// hdc/hglrc only before the renderer thread spawns (init) and after
/// it is joined (deinit), so there is no race. We do NOT re-run
/// setupPixelFormat: SetPixelFormat is once-per-window and the
/// CS_OWNDC device context keeps its format.
pub fn recreateGLContext(self: *Surface) !void {
    const hdc = self.hdc orelse return error.Win32Error;

    // Create the new context before deleting the old one so a failed
    // allocation does not discard the surface's last context handle.
    const new = w32.wglCreateContext(hdc) orelse return error.Win32Error;

    _ = w32.wglMakeCurrent(null, null);
    if (self.hglrc) |old| _ = w32.wglDeleteContext(old);
    self.hglrc = new;

    if (w32.wglMakeCurrent(hdc, new) == 0) return error.Win32Error;
    disableSwapWait();
}

/// Present frames without waiting for the display in SwapBuffers. The
/// renderer paces its own frames and DWM composes windowed OpenGL in
/// step with the display anyway, so the wait only added latency, and
/// with the display off after sleep some drivers never returned from it,
/// wedging the renderer. Needs a current context.
fn disableSwapWait() void {
    const SwapInterval = *const fn (c_int) callconv(.winapi) c_int;
    const proc = w32.wglGetProcAddress("wglSwapIntervalEXT") orelse return;
    const set_interval: SwapInterval = @ptrCast(proc);
    _ = set_interval(0);
}

/// Set up a pixel format suitable for OpenGL rendering.
fn setupPixelFormat(self: *Surface) !void {
    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 8,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = 0, // PFD_MAIN_PLANE
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const format = w32.ChoosePixelFormat(self.hdc.?, &pfd);
    if (format == 0) return error.Win32Error;

    if (w32.SetPixelFormat(self.hdc.?, format, &pfd) == 0)
        return error.Win32Error;
}

/// Update the DPI scale factor from the window's DPI.
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

/// Update the cached client area size.
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by the core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    // Signal failure rather than returning a bogus {0,0} origin, so the
    // core skips the mouse computation instead of resolving it against the
    // top-left cell (which produced spurious hover/selection at 0,0).
    return error.GetCursorPosFailed;
}

pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    if (self.title_len == 0) return null;
    return self.title[0..self.title_len :0];
}

/// Notify the core whether this surface is currently visible. When a surface
/// is occluded (background tab, hidden split-zoom pane, minimized window) the
/// renderer skips rebuilding/rendering frames until it is visible again
/// (src/renderer/Thread.zig). We must dedupe redundant states here on the
/// producer side: the core pushes every call into the renderer mailbox with
/// a bounded timeout, and the consumer-side dedupe in the renderer thread
/// never runs while that mailbox is undrained, so unconditionally
/// re-asserting the same visibility on every layout pass (one per WM_SIZE)
/// would fill the queue and stall the GUI thread for the push timeout each,
/// then drop.
pub fn setVisible(self: *Surface, visible: bool) void {
    // Hide the hovered-URL bubble when this surface is occluded so a stale
    // preview doesn't float over the newly-active tab.
    if (!visible) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    if (!self.core_surface_ready) return;
    if (self.last_reported_visible == visible) return;
    self.last_reported_visible = visible;
    self.core_surface.occlusionCallback(visible) catch |err| {
        // Not delivered (mailbox full or wakeup failed): clear the
        // latch so the next call retries instead of treating this
        // state as sent — otherwise a dropped .visible=true could
        // leave the renderer invisible forever.
        self.last_reported_visible = null;
        log.warn("occlusionCallback failed err={}", .{err});
    };
}

pub fn close(self: *Surface, process_active: bool) void {
    log.debug("Surface.close called process_active={}", .{process_active});
    // If a shell command is still running, prompt the user before
    // closing. Without this, Ctrl+Shift+W silently kills the running
    // process — macOS shows the same kind of dialog for parity. We
    // only prompt for programmatic close paths; the X-button path
    // bypasses needsConfirmQuit entirely (cmd.exe lacks OSC 133 so
    // the core would return process_active=true unconditionally).
    if (process_active) {
        const parent_hwnd = self.parent_window.hwnd;
        const result = w32.MessageBoxW(
            parent_hwnd,
            std.unicode.utf8ToUtf16LeStringLiteral(
                "A process is still running in this terminal.\nClose anyway?",
            ),
            std.unicode.utf8ToUtf16LeStringLiteral(brand.name),
            w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
        );
        if (result != w32.IDOK) return;
    }
    // Defer destruction to the message loop via PostMessage.
    // This avoids calling surface.deinit() from inside core_surface
    // callbacks (during tick), which causes reentrancy and crashes.
    // The WM_CLOSE handler in surfaceWndProc will call closeTab.
    if (self.hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    }
}

// The core calls these on the apprt surface; clipboard.zig does the work.
pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    return clipboard.supportsClipboard(self, clipboard_type);
}

pub fn clipboardRequest(self: *Surface, clipboard_type: apprt.Clipboard, state: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
    return clipboard.clipboardRequest(self, clipboard_type, state);
}

pub fn setClipboard(self: *Surface, clipboard_type: apprt.Clipboard, contents: []const apprt.ClipboardContent, confirm: bool) !void {
    return clipboard.setClipboard(self, clipboard_type, contents, confirm);
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    const env = try global.environMap();

    // TERM and COLORTERM are set by termio/Exec.zig with platform-aware
    // logic (checking for terminfo, resources_dir, etc.). Do not set them here.

    return env;
}

/// Remember the shell's working directory, which the tab sidebar groups
/// by and the session restores. Stored with backslashes and no trailing
/// separator, except for a drive root ("C:\\").
/// Returns whether the folder changed.
pub fn setFolder(self: *Surface, path: []const u8) bool {
    // The path comes from the program's OSC 7. One that doesn't fit would
    // be a different folder once cut, and control characters or "|" could
    // forge lines in the session file.
    if (path.len > self.folder.len) return false;
    for (path) |c| if (c < 0x20 or c == 0x7F or c == '|') return false;
    var trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 2 and trimmed[1] == ':') trimmed = path[0..@min(path.len, 3)];
    const n = @min(trimmed.len, self.folder.len);
    var next: [260]u8 = undefined;
    for (trimmed[0..n], next[0..n]) |c, *out| out.* = if (c == '/') '\\' else c;
    if (n == self.folder_len and std.mem.eql(u8, next[0..n], self.folder[0..n])) return false;
    @memcpy(self.folder[0..n], next[0..n]);
    self.folder_len = @intCast(n);
    return true;
}

/// Returns whether it changed.
pub fn setClaudeSession(self: *Surface, session: ?claude_session.Session) bool {
    if (claude_session.Session.eql(self.claude, session)) return false;
    self.claude = session;
    return true;
}

pub fn sshHost(self: *const Surface) []const u8 {
    return self.ssh_host[0..self.ssh_host_len];
}

/// Returns whether the host changed.
pub fn setSshHost(self: *Surface, detected: []const u8) bool {
    // Read from another process's command line: anything that couldn't be
    // an ssh destination (and could break the session file) counts as none.
    const host = if (servers.valid(detected)) detected else "";
    const n: u8 = @intCast(@min(host.len, self.ssh_host.len));
    if (n == self.ssh_host_len and std.mem.eql(u8, host[0..n], self.ssh_host[0..n])) return false;
    @memcpy(self.ssh_host[0..n], host[0..n]);
    self.ssh_host_len = n;
    return true;
}

fn setHomeFolder(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const home = global.environ().getAlloc(alloc, "USERPROFILE") catch return;
    defer alloc.free(home);
    _ = self.setFolder(home);
}

/// The full path of the folder the shell is in.
pub fn folderPath(self: *const Surface) []const u8 {
    return self.folder[0..self.folder_len];
}

/// The folder's own name, as the sidebar shows it.
pub fn folderName(self: *const Surface) []const u8 {
    const path = self.folderPath();
    const start = if (std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, path, "\\"), '\\')) |i| i + 1 else 0;
    return std.mem.trimEnd(u8, path[start..], "\\");
}

pub fn profileName(self: *const Surface) []const u8 {
    return self.profile_name[0..self.profile_name_len];
}

/// Set the window title. Called from performAction(.set_title).
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const len = @min(title.len, self.title.len - 1);
    @memcpy(self.title[0..len], title[0..len]);
    self.title[len] = 0;
    self.title_len = len;
    self.parent_window.onTabTitleChanged(self, title);
}

/// Toggle fullscreen mode. Delegates to the parent Window.
pub fn toggleFullscreen(self: *Surface) void {
    self.parent_window.toggleFullscreen();
}

/// Toggle window decorations (title bar + borders) on/off.
/// Delegates to the parent Window.
pub fn toggleWindowDecorations(self: *Surface) void {
    self.parent_window.toggleWindowDecorations();
}

/// Update the themed scrollbar to reflect the terminal's scroll state.
/// Called from performAction(.scrollbar) when the viewport changes.
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    if (self.scrollbar) |sb| sb.update(scrollbar);
}

/// Scroll the terminal to the given absolute row offset.
/// Called by the themed scrollbar during drag / click.
pub fn scrollToOffset(self: *Surface, offset: usize) void {
    if (!self.core_surface_ready) return;
    _ = self.core_surface.performBindingAction(.{ .scroll_to_row = offset }) catch |err| {
        log.err("scrollToOffset error: {}", .{err});
    };
}

// -----------------------------------------------------------------------
// Message handlers called from App.surfaceWndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    // Skip zero-size events (minimized windows).
    if (width == 0 or height == 0) return;

    self.height = height;

    // Pre-flight the scrollbar so we know whether to subtract its width.
    // This must happen before sizeCallback so the grid gets the right width.
    var grid_width = width;
    if (self.scrollbar) |sb| {
        const sub = sb.repositionAndResize();
        if (sub > 0 and grid_width > @as(u32, @intCast(sub))) {
            grid_width -= @as(u32, @intCast(sub));
        }
    }
    self.width = grid_width;

    // Reposition popups with corrected width.
    if (self.search_active) find_bar.positionSearchBar(self);
    if (self.palette_active) command_palette.positionCommandPalette(self);

    if (!self.core_surface_ready) return;

    // Notify the core surface so it recalculates the terminal grid,
    // updates the renderer viewport, and sends SIGWINCH to the PTY.
    self.core_surface.sizeCallback(.{ .width = grid_width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };

    // Every resize (a border drag, maximizing, snapping, the sidebar's
    // edge) blocks until the renderer has presented a frame at the new
    // size, or briefly gives up, so the window never shows the pane at
    // its new size with only its old frame or its background in it.
    if (self.frame_event) |event| {
        // Reset before waking the renderer, so we wait for a NEW frame.
        _ = w32.ResetEvent(event);
    }
    self.core_surface.renderer_thread.wakeup.notify() catch {};
    if (self.frame_event) |event| {
        // A short timeout so a slow renderer never stalls the UI.
        _ = w32.WaitForSingleObject(event, 16);
    }
}

/// Handle WM_DPICHANGED.
pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();

    // Popup fonts were created at the previous DPI. Rebuild them at
    // the new scale so search-bar / palette text doesn't render
    // tiny/huge after dragging the window between monitors.
    const s = self.scale;
    if (self.search_font) |old| {
        _ = w32.DeleteObject(old);
        self.search_font = null;
    }
    if (self.palette_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_font = null;
    }
    if (self.palette_paint_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_paint_font = null;
    }
    if (self.search_edit) |edit| {
        self.search_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        if (self.search_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
            // The count label shares the search font; re-send it too or the
            // label keeps a handle to the just-deleted HFONT.
            if (self.search_count_label) |label| {
                _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    if (self.palette_edit) |edit| {
        self.palette_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        if (self.palette_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    // Notify the scrollbar of the new DPI.
    if (self.scrollbar) |sb| sb.onDpiChanged(@intFromFloat(self.scale * 96.0));
}

/// Handle WM_KEYDOWN / WM_SYSKEYDOWN / WM_KEYUP / WM_SYSKEYUP.
pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);

    // When the IME is active, physical key presses arrive as VK_PROCESSKEY.
    // The IME will produce the composed text via WM_IME_COMPOSITION — skip
    // the key event so we don't feed garbage to the terminal.
    if (vk == w32.VK_PROCESSKEY) return;

    // VK_PACKET is sent by SendInput with KEYEVENTF_UNICODE (used by
    // accessibility tools, on-screen keyboards, and Unicode injection).
    // The actual character follows as WM_CHAR — don't set the
    // key_event_produced_text flag so WM_CHAR is allowed through.
    if (vk == w32.VK_PACKET) return;

    // Determine left/right for modifier keys using the extended key flag
    // (bit 24 of lparam) and specific left/right VK codes.
    const extended = (lparam & (1 << 24)) != 0;

    const key = key_map.mapVirtualKey(vk, extended);

    // Build modifier state
    const mods = key_map.getModifiers();

    // Win32 Input Mode (mode 9001): encode key events as
    // \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences that ConPTY reconstructs
    // into INPUT_RECORD structs. This provides full Unicode support
    // and bypasses ConPTY codepage issues.
    //
    // We still need to check keybindings first (e.g., Ctrl+Shift+C
    // for copy) so they work in this mode. Only fall through to
    // Win32 input encoding if no binding matched.
    if (win32_input.isWin32InputMode(self)) {
        if (key.modifier()) {
            // Modifier keys bypass keyCallback in this mode, but link hover
            // still needs updating when Ctrl/Shift change under a stationary
            // pointer. This callback only updates UI state; the original
            // Win32 input event below remains the sole input sent to ConPTY.
            self.core_surface.modifiersChangedCallback(mods) catch |err| {
                log.err("modifier callback error: {}", .{err});
            };
        }

        // Check keybindings for non-modifier keys (Ctrl+Shift+C, etc.).
        // Modifier-only keys never have bindings, and sending them
        // through keyCallback would clear the selection.
        if (!key.modifier()) {
            const actual_action_w32 = if (action == .press and (lparam & (1 << 30)) != 0)
                input.Action.repeat
            else
                action;
            const unshifted_cp: u21 = if (key.codepoint()) |cp| cp else 0;
            const effect = self.core_surface.keyCallback(.{
                .action = actual_action_w32,
                .key = key,
                .mods = mods,
                .consumed_mods = .{},
                .utf8 = "", // no text — let Win32 input handle it
                .unshifted_codepoint = unshifted_cp,
            }) catch |err| {
                log.err("key callback error: {}", .{err});
                return;
            };
            // If a keybinding consumed the event, don't send Win32 input.
            if (effect == .consumed or effect == .closed) return;
        }

        // No binding matched — send as Win32 input sequence.
        win32_input.sendWin32InputEvent(self, vk, lparam, action);
        return;
    }

    // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
    // if the key was already down).
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    // Try to get the unshifted codepoint for this key
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

    // Use ToUnicode to translate the key press into UTF-16 text,
    // then convert to UTF-8 for the key event. Only for press/repeat.
    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};
    // The modifier set actually encoded into the key event. AltGr handling
    // below may clear ctrl+alt on this copy without disturbing `mods`.
    var event_mods = mods;

    // Reset the flag — WM_CHAR should be allowed through unless
    // ToUnicode produces text below.
    self.key_event_produced_text = false;

    if ((actual_action == .press or actual_action == .repeat) and !key_map.isModifierVk(vk)) {
        // App.run skips TranslateMessage for surface keyboard messages, so
        // this ToUnicode call owns the per-queue dead-key state. result>0
        // means composed text (including composition with a previously
        // pending dead key); result<0 means VK is itself a dead key and
        // ToUnicode just stored it for the next call.
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            // Mask to 8 bits — bit 24 of lparam is the extended-key flag,
            // not part of the scancode. Including it broke ToUnicode for
            // AltGr layouts (German, Polish) and arrow/numpad keys.
            const scancode: u32 = @intCast((lparam >> 16) & 0xFF);
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                // Skip Ctrl-induced control chars (0x01-0x1A): the core
                // handles modifier combos via key + mods, and emitting
                // the control char here would double-encode.
                if (utf16_slice[0] >= 0x20) {
                    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_slice) catch 0;
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        if (mods.shift) consumed_mods.shift = true;
                        self.key_event_produced_text = true;
                        // AltGr layouts: Windows reports AltGr as
                        // Left-Ctrl+Right-Alt. When that combination itself
                        // produced printable text (e.g. German AltGr+Q '@',
                        // AltGr+8 '['), strip ctrl+alt from the ENCODED mods.
                        // The core key encoder reads raw event.mods and would
                        // otherwise turn the literal into a C0/CSIu control
                        // sequence. Gate on the right-Alt physically being down
                        // so genuine Ctrl+Alt chords are left untouched.
                        if (mods.ctrl and mods.alt and
                            (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                        {
                            event_mods.ctrl = false;
                            event_mods.alt = false;
                            consumed_mods.ctrl = true;
                            consumed_mods.alt = true;
                        }
                    }
                }
            }
        }
    }

    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    };

    _ = self.core_surface.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}

/// Handle WM_CHAR — character input after translation.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages
/// containing a UTF-16 surrogate pair (high then low).
///
/// Text is routed through keyCallback (not textCallback!) with
/// key=.unidentified, mirroring how GTK handles IME commits.
/// textCallback is for clipboard paste; keyCallback is for keyboard/IME text.
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    // Skip control characters that are handled via WM_KEYDOWN
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    // Handle UTF-16 surrogate pairs for codepoints > U+FFFF (e.g. emoji).
    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        // High surrogate — buffer it and wait for the low surrogate.
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        // Low surrogate — combine with buffered high surrogate.
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        // Low surrogate without preceding high — invalid, skip.
        return;
    } else blk: {
        self.high_surrogate = 0; // Reset any stale high surrogate.
        break :blk @intCast(char_code);
    };

    // Convert codepoint to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    // keyCallback will encode the utf8 text and write it to the PTY.
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}

/// Called by the renderer thread after each frame it updates and draws:
/// logs it for the performance benchmark (frame_log.zig) and paces the
/// next one to the display (frame_pacer.zig).
pub fn frameDrawn(self: *Surface, total_ns: u64, swap_ns: u64) void {
    frame_log.record(total_ns, swap_ns);
    self.frame_pacer.frameDone(self.hdc);
}

/// Called by the renderer thread after SwapBuffers to signal that a
/// frame has been presented. Wakes the main thread if it's blocking
/// in handleResize during live resize.
pub fn signalFrameDrawn(self: *Surface) void {
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}

/// Handle WM_SETFOCUS / WM_KILLFOCUS.
pub fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.core_surface_ready) return;
    // Drop any buffered high surrogate and pending dead key on focus loss —
    // otherwise they would combine with the next character when focus returns.
    if (!focused) {
        self.high_surrogate = 0;
        // Composition messages follow keyboard focus, so a split losing
        // focus mid-composition never gets its own WM_IME_ENDCOMPOSITION.
        // Cancel the composition and clear its inline preedit now.
        if (self.ime_composing) {
            self.ime_composing = false;
            if (self.hwnd) |hwnd| {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    defer _ = w32.ImmReleaseContext(hwnd, himc);
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                }
            }
            self.core_surface.preeditCallback(null) catch {};
        }
        // Drain any pending dead-key state so an unfinished compose
        // doesn't bleed into the next focused surface or another app.
        var ks: [256]u8 = undefined;
        if (w32.GetKeyboardState(&ks) != 0) {
            var buf: [4]u16 = undefined;
            // 0x39 is the standard scancode for VK_SPACE on all layouts.
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
        }
    }
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}

/// Return a pointer to the core terminal surface.
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

/// Return a reference to the App for use by core code.
pub fn rtApp(self: *Surface) *App {
    return self.app;
}

test "Win32 modifier releases clear link hover without changing selection or input" {
    const testing = std.testing;
    const Native = struct {
        extern "user32" fn SetKeyboardState(state: *const [256]u8) callconv(.winapi) i32;
        extern "user32" fn GetCursor() callconv(.winapi) ?w32.HCURSOR;
    };

    // SetKeyboardState affects only this thread's input queue. Never inject
    // global input or move the real pointer to test a modifier transition.
    var saved_keys: [256]u8 = undefined;
    if (w32.GetKeyboardState(&saved_keys) == 0) return error.Win32Error;
    defer _ = Native.SetKeyboardState(&saved_keys);
    const saved_cursor = Native.GetCursor();
    defer _ = w32.SetCursor(saved_cursor);

    const Release = struct {
        vk: u16,
        scancode: u16,
        remaining: input.Mods,
        expected_input: []const u8,
    };
    const orders = [_][2]Release{
        .{
            .{ .vk = w32.VK_SHIFT, .scancode = 42, .remaining = .{ .ctrl = true }, .expected_input = "\x1b[16;42;0;0;8;1_" },
            .{ .vk = w32.VK_CONTROL, .scancode = 29, .remaining = .{}, .expected_input = "\x1b[17;29;0;0;0;1_" },
        },
        .{
            .{ .vk = w32.VK_CONTROL, .scancode = 29, .remaining = .{ .shift = true }, .expected_input = "\x1b[17;29;0;0;16;1_" },
            .{ .vk = w32.VK_SHIFT, .scancode = 42, .remaining = .{}, .expected_input = "\x1b[16;42;0;0;0;1_" },
        },
    };

    for (orders) |order| {
        var core_app: @import("../../App.zig") = undefined;
        core_app.alloc = testing.allocator;
        var app: App = undefined;
        app.core_app = &core_app;
        const surface = try testing.allocator.create(Surface);
        defer testing.allocator.destroy(surface);
        surface.* = .{ .app = &app, .core_surface_ready = true };

        const core_surface = &surface.core_surface;
        core_surface.alloc = testing.allocator;
        core_surface.readonly = false;
        core_surface.rt_app = &app;
        core_surface.rt_surface = surface;
        core_surface.config.mouse_shift_capture = .false;
        core_surface.config.mouse_reporting = true;
        core_surface.mouse = .{
            .mods = .{ .ctrl = true, .shift = true },
            .over_link = true,
            .link_point = .{ .x = 1, .y = 0 },
        };
        core_surface.io.terminal = try terminal.Terminal.init(global.io(), testing.allocator, .{ .cols = 8, .rows = 2 });
        defer core_surface.io.terminal.deinit(testing.allocator);
        const term = &core_surface.io.terminal;
        term.modes.set(.win32_input, true);
        term.flags.mouse_event = .any;
        term.flags.mouse_shift_capture = .false;
        term.mouse_shape = .crosshair;
        const screen = term.screens.active;
        try screen.select(terminal.Selection.init(
            screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
            false,
        ));
        const selection = screen.selection.?;

        var mutex: std.Io.Mutex = .init;
        core_surface.renderer_state = .{
            .mutex = &mutex,
            .terminal = term,
            .mouse = .{ .mods = .{ .ctrl = true }, .point = .{ .x = 1, .y = 0 } },
        };
        core_surface.renderer_thread.wakeup = try global.xev.Async.init();
        defer core_surface.renderer_thread.wakeup.deinit();
        core_surface.io.mailbox = try termio.Mailbox.initSPSC(testing.allocator);
        defer core_surface.io.mailbox.deinit(testing.allocator);
        surface.current_cursor = w32.LoadCursorW(null, w32.IDC_HAND);

        for (order) |release| {
            var keys: [256]u8 = @splat(0);
            if (release.remaining.ctrl) {
                keys[w32.VK_CONTROL] = 0x80;
                keys[w32.VK_LCONTROL] = 0x80;
            }
            if (release.remaining.shift) {
                keys[w32.VK_SHIFT] = 0x80;
                keys[w32.VK_LSHIFT] = 0x80;
            }
            if (Native.SetKeyboardState(&keys) == 0) return error.Win32Error;
            const lparam: isize = (@as(isize, release.scancode) << 16) | 1;
            surface.handleKeyEvent(release.vk, lparam, .release);

            // No HWND is needed: losing the link must clear stale hover
            // even when a stationary cursor's position cannot be queried.
            try testing.expect(!core_surface.mouse.over_link);
            try testing.expect(core_surface.mouse.link_point == null);
            try testing.expect(core_surface.renderer_state.mouse.point == null);
            try testing.expect(core_surface.mouse.mods.equal(release.remaining));
            const cursor_id = if (release.remaining.shift) w32.IDC_IBEAM else w32.IDC_CROSS;
            try testing.expectEqual(w32.LoadCursorW(null, cursor_id), surface.current_cursor);
            try testing.expectEqualDeep(selection, screen.selection.?);

            const msg = core_surface.io.mailbox.spsc.queue.pop(global.io()) orelse return error.ExpectedKeyRelease;
            defer msg.deinit();
            switch (msg) {
                .write_small => |write| try testing.expectEqualStrings(release.expected_input, write.data[0..write.len]),
                else => return error.UnexpectedInputMessage,
            }
            try testing.expect(core_surface.io.mailbox.spsc.queue.pop(global.io()) == null);
        }
    }
}

test "read-only blocks native keyboard character and IME input" {
    const testing = std.testing;
    const Native = struct {
        extern "user32" fn SetKeyboardState(state: *const [256]u8) callconv(.winapi) i32;
    };
    var saved_keys: [256]u8 = undefined;
    if (w32.GetKeyboardState(&saved_keys) == 0) return error.Win32Error;
    defer _ = Native.SetKeyboardState(&saved_keys);
    const keys: [256]u8 = @splat(0);
    if (Native.SetKeyboardState(&keys) == 0) return error.Win32Error;

    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.* = .{ .app = &app, .core_surface_ready = true };
    const core_surface = &surface.core_surface;
    core_surface.mouse = .{};
    core_surface.io.terminal = try terminal.Terminal.init(global.io(), testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core_surface.io.terminal.deinit(testing.allocator);
    core_surface.io.terminal.modes.set(.win32_input, true);
    var mutex: std.Io.Mutex = .init;
    core_surface.renderer_state.mutex = &mutex;
    core_surface.io.mailbox = try termio.Mailbox.initSPSC(testing.allocator);
    defer core_surface.io.mailbox.deinit(testing.allocator);

    // Only this thread's keyboard state changes. The real native emitters
    // run without an HWND, renderer, child process, or global input.
    for ([_]bool{ true, false }) |readonly| {
        core_surface.readonly = readonly;
        win32_input.sendWin32InputEvent(surface, w32.VK_RETURN, (28 << 16) | 1, .press);
        win32_input.sendWin32InputEvent(surface, w32.VK_RETURN, (28 << 16) | 1, .release);
        surface.handleKeyEvent(w32.VK_CONTROL, (29 << 16) | 1, .press);
        surface.handleKeyEvent(w32.VK_CONTROL, (29 << 16) | 1, .release);
        win32_input.sendWin32CharEvent(surface, 'x');
        ime.sendImeText(surface, &.{ 0x4E2D, 0xD83D, 0xDE00 });

        const expected = [_][]const u8{
            "\x1b[13;28;13;1;0;1_",  "\x1b[13;28;0;0;0;1_",
            "\x1b[17;29;0;1;0;1_",   "\x1b[17;29;0;0;0;1_",
            "\x1b[0;0;120;1;0;1_",   "\x1b[0;0;120;0;0;1_",
            "\x1b[0;0;20013;1;0;1_", "\x1b[0;0;20013;0;0;1_",
            "\x1b[0;0;55357;1;0;1_", "\x1b[0;0;55357;0;0;1_",
            "\x1b[0;0;56832;1;0;1_", "\x1b[0;0;56832;0;0;1_",
        };
        if (!readonly) for (expected) |sequence| {
            const msg = core_surface.io.mailbox.spsc.queue.pop(global.io()) orelse return error.ExpectedInput;
            defer msg.deinit();
            switch (msg) {
                .write_small => |write| try testing.expectEqualStrings(sequence, write.data[0..write.len]),
                else => return error.UnexpectedInput,
            }
        };
        const extra = core_surface.io.mailbox.spsc.queue.pop(global.io());
        defer if (extra) |msg| msg.deinit();
        try testing.expect(extra == null);
    }
}
