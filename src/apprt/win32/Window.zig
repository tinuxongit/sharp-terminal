//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabOverview = @import("TabOverview.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const wide_string = @import("wide_string.zig");
const tab_strip = @import("tab_strip.zig");
const menu_theme = @import("menu_theme.zig");
const SettingsPanel = @import("SettingsPanel.zig");
const profiles = @import("profiles.zig");
const new_tab_menu = @import("new_tab_menu.zig");
const tab_sidebar = @import("tab_sidebar.zig");
const canvas_mod = @import("canvas.zig");
const SearchField = @import("SearchField.zig");
const session = @import("session.zig");
const servers = @import("servers.zig");
const configpkg = @import("../../config.zig");
const workspace = @import("workspace.zig");
const tab_rename = @import("tab_rename.zig");
const splits = @import("splits.zig");
const actions = @import("actions.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const MAX_TABS: usize = 64;
const WM_TOGGLE_TAB_OVERVIEW = w32.WM_APP + 5;
const WM_REFRESH_TAB_OVERVIEW = w32.WM_APP + 6;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_overview: TabOverview = .{},
overview_refresh_pending: bool = false,
tab_trees: [64]SplitTree(Surface) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [64]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the strip shows tabs (see updateTabBarVisibility).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// What the pointer is over in the tab strip, and which caption button is
/// held down. Caption buttons act on release, like the Windows ones.
strip_hover: tab_strip.Part = .none,
strip_pressed: tab_strip.Part = .none,

/// Whether this window has focus. Inactive windows dim the strip.
window_active: bool = true,

/// Tab width held while tabs are being closed with the mouse.
frozen_tab_width: ?i32 = null,

/// The settings panel, while it is open.
settings_panel: ?*SettingsPanel = null,

/// The tab sidebar's state, used when `window-tab-bar-position = sidebar`.
sidebar_fonts: tab_sidebar.Fonts = .{},
sidebar_search: SearchField = .{},
/// The address box Servers' "+" opens; shown while it has the keyboard.
server_field: SearchField = .{},
/// Whether WSL is installed, so the sidebar always shows its section.
has_wsl: bool = false,
sidebar_hover: tab_sidebar.Target = .none,
/// The sidebar arrow whose shell menu is open.
sidebar_pressed: tab_sidebar.Target = .none,
sidebar_scroll: i32 = 0,
sidebar_max_scroll: i32 = 0,
sidebar_spots: tab_sidebar.Spots = .{},
/// Sidebar width in pixels at 96 DPI, which the user can drag.
sidebar_width: f32 = tab_sidebar.default_width,
sidebar_resizing: bool = false,
/// A tab pressed in the sidebar, and whether it has moved enough to drag.
sidebar_drag: ?usize = null,
sidebar_drag_y: i32 = 0,
sidebar_dragging: bool = false,
/// Folders (or servers) the user folded in the sidebar.
collapsed: [max_collapsed][300]u8 = undefined,
collapsed_lens: [max_collapsed]u16 = undefined,
collapsed_count: usize = 0,
/// Counts the sidebar timer's ticks, to refresh ages once a minute.
sidebar_ticks: u32 = 0,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [64][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [64]u16 = undefined,

/// Explicit top-level window title override. Null follows the active tab.
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Fonts for the tab strip's titles and icons, sized for `scale`.
strip_fonts: tab_strip.Fonts = .{},

/// Whether WM_MOUSELEAVE tracking is active for the tab bar, and
/// WM_NCMOUSELEAVE tracking for the caption buttons.
tracking_mouse: bool = false,
tracking_nc_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Transient "columns × rows" overlay shown while resizing
/// (resize-overlay config). Owned popup: destroyed with the window.
resize_overlay_hwnd: ?w32.HWND = null,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
resize_seen_first: bool = false,

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Read HKCU\...\Themes\Personalize\AppsUseLightTheme. Returns true when the
/// system apps theme is light. A missing/erroring value is treated as light,
/// which is how the Personalize key reads before it is ever written.
pub fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD) return true;
    return val != 0; // 0 = dark, nonzero = light
}

/// Apply the DWM dark/light title bar, honoring `window-theme`: dark/light
/// force the mode, `system` reads the OS apps theme, and `auto`/`ghostty`
/// fall back to the terminal background luminance. The caption is tinted to
/// the terminal background only for the luminance-derived themes; for the
/// explicit dark/light/system themes the caption is reset to the system
/// default so the standard themed title bar (and legible glyphs) is drawn.
fn applyChromeTheme(hwnd: w32.HWND, theme: anytype, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const by_luminance = luminance < 0.5;
    const dark = switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => by_luminance,
    };

    const dark_mode: u32 = if (dark) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Called from App.config_change so the title bar tracks live config
/// reloads (background color in particular).
/// Enable/disable the DWM accent blur behind the window (background-blur).
/// Visible where the window is translucent (background-opacity < 1): the
/// desktop behind shows blurred instead of sharp, the acrylic-ish look.
fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = if (enabled) w32.ACCENT_ENABLE_BLURBEHIND else w32.ACCENT_DISABLED,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = @ptrCast(&policy),
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    _ = w32.SetWindowCompositionAttribute(hwnd, &data);
}

pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.@"window-theme", self.app.config.background);
        applyBackgroundBlur(hwnd, self.app.config.@"background-blur".enabled());
    }
    self.tab_overview.updateAppearance();
    // The strip's colors come from the terminal's, so a new theme repaints
    // it, and the tabs may have moved between the strip and the sidebar.
    self.updateTabBarVisibility();
    self.handleResize();
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    // WS_CLIPCHILDREN keeps the window's own painting (the strip, the
    // sidebar, newly exposed edges) off the terminal panes.
    const style: u32 = w32.WS_CLIPCHILDREN | @as(u32, if (options.is_quick_terminal)
        w32.WS_POPUP
    else if (app.config.@"window-decoration" == .none)
        // Borderless but still resizable: thin sizing frame, no title bar.
        w32.WS_POPUP | w32.WS_THICKFRAME
    else
        w32.WS_OVERLAPPEDWINDOW);
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    // Cascade non-quick-terminal windows: stack each new window 30px
    // down/right of the most recently created window. Stops once the
    // offset would push the window off the work area, then resets.
    // Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    // Honor an explicit configured window position; it takes precedence over
    // the cascade below. Only when BOTH coordinates are set — passing
    // CW_USEDEFAULT for one axis is not a valid literal coordinate (Win32
    // only special-cases it on x, and would use a huge negative y or treat
    // y as nCmdShow), so a partial config falls back to full default.
    if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (!options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(brand.name),
        style,
        cx,
        cy,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    applyChromeTheme(hwnd, app.config.@"window-theme", app.config.background);

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    // Skip when force_opaque (parent window was toggled to opaque via
    // toggle_background_opacity — inherit that state for the new window).
    if (app.config.@"background-opacity" < 1.0 and !options.force_opaque) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }
    if (app.config.@"background-blur".enabled()) {
        applyBackgroundBlur(hwnd, true);
    }

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    self.loadStripFonts();
    _ = w32.SetTimer(hwnd, SIDEBAR_TIMER_ID, SIDEBAR_TIMER_MS, null);

    // WM_NCCALCSIZE during CreateWindowExW ran before GWLP_USERDATA was
    // set, so the default caption was laid out. Recompute the frame now
    // that the tab strip can take its place.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    self.tab_overview.deinit();
    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    self.strip_fonts.deinit();

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab strip height in pixels, accounting for DPI scale.
/// Returns 0 if the strip is not shown.
pub fn tabBarHeight(self: *const Window) i32 {
    return self.stripLayout().height();
}

/// Whether the tab strip replaces the Windows title bar. Only normal
/// decorated windows do this: the quick terminal, fullscreen and windows
/// without decorations keep the default frame handling.
fn integratedTitleBar(self: *const Window) bool {
    if (self.is_quick_terminal or self.is_fullscreen) return false;
    const hwnd = self.hwnd orelse return false;
    return (w32.GetWindowLongW(hwnd, w32.GWL_STYLE) & w32.WS_CAPTION) == w32.WS_CAPTION;
}

pub fn stripLayout(self: *const Window) tab_strip.Layout {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.hwnd) |hwnd| _ = w32.GetClientRect(hwnd, &client);
    return .{
        .scale = self.scale,
        .style = switch (self.app.config.@"window-tab-style") {
            .chrome => .chrome,
            .@"windows-terminal" => .windows_terminal,
        },
        .width = client.right - client.left,
        .tab_count = self.tab_count,
        .active = self.active_tab,
        .show_tabs = self.tab_bar_visible and !self.sidebarMode(),
        .sidebar = self.sidebarMode(),
        .caption_buttons = self.integratedTitleBar(),
        .frozen_tab_width = self.frozen_tab_width,
    };
}

fn loadStripFonts(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const hdc = w32.GetDC(hwnd) orelse return;
    defer _ = w32.ReleaseDC(hwnd, hdc);
    self.strip_fonts.deinit();
    self.strip_fonts = .init(hdc, self.scale);
    self.sidebar_fonts.deinit();
    self.sidebar_fonts = .init(hdc, self.scale);
    self.has_wsl = profiles.detect().first(.wsl) != null;
}

fn setStripHover(self: *Window, part: tab_strip.Part) void {
    if (part.eql(self.strip_hover)) return;
    self.strip_hover = part;
    self.invalidateTabBar();
}

/// Window border thickness at this DPI. With the caption removed it is
/// both the top resize band and how far a maximized window hangs past
/// the screen edge.
fn frameThickness(self: *const Window) i32 {
    const dpi: u32 = @intFromFloat(@round(self.scale * 96.0));
    return w32.GetSystemMetricsForDpi(w32.SM_CYFRAME, dpi) +
        w32.GetSystemMetricsForDpi(w32.SM_CXPADDEDBORDER, dpi);
}

/// WM_NCCALCSIZE for the integrated title bar: keep the default side and
/// bottom borders, which carry the resize handles and shadow, but hand the
/// caption area to the client so the tab strip can draw there.
fn calcClientArea(self: *Window, hwnd: w32.HWND, wparam: usize, lparam: isize) isize {
    const params: *w32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const top = params.rgrc[0].top;
    const result = w32.DefWindowProcW(hwnd, w32.WM_NCCALCSIZE, wparam, lparam);
    params.rgrc[0].top = top;
    if (w32.IsZoomed(hwnd) != 0) params.rgrc[0].top += self.frameThickness();
    return result;
}

/// WM_NCHITTEST for the integrated title bar. Reporting the caption
/// buttons as HTMINBUTTON/HTMAXBUTTON/HTCLOSE keeps Windows 11's snap
/// layouts flyout on the maximize button.
fn hitTestFrame(self: *Window, hwnd: w32.HWND, lparam: isize) isize {
    const hit = w32.DefWindowProcW(hwnd, w32.WM_NCHITTEST, 0, lparam);
    if (hit != w32.HTCLIENT) return hit;

    var pt: w32.POINT = .{
        .x = @as(i16, @truncate(lparam & 0xFFFF)),
        .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
    };
    _ = w32.ScreenToClient(hwnd, &pt);
    const layout = self.stripLayout();

    // The top border now belongs to the client, so top-edge resizing has
    // to be reported here.
    const band = self.frameThickness();
    if (w32.IsZoomed(hwnd) == 0 and pt.y >= 0 and pt.y < band) {
        if (pt.x < 2 * band) return w32.HTTOPLEFT;
        if (pt.x >= layout.width - 2 * band) return w32.HTTOPRIGHT;
        return w32.HTTOP;
    }

    return switch (layout.hitTest(pt.x, pt.y)) {
        .minimize => w32.HTMINBUTTON,
        .maximize => w32.HTMAXBUTTON,
        .close => w32.HTCLOSE,
        .caption => w32.HTCAPTION,
        else => w32.HTCLIENT,
    };
}

/// The caption button a WM_NC* message's hit-test code refers to.
fn captionButtonAt(wparam: usize) ?tab_strip.Part {
    return switch (@as(isize, @bitCast(wparam))) {
        w32.HTMINBUTTON => .minimize,
        w32.HTMAXBUTTON => .maximize,
        w32.HTCLOSE => .close,
        else => null,
    };
}

fn pressCaptionButton(self: *Window, button: tab_strip.Part) void {
    const hwnd = self.hwnd orelse return;
    switch (button) {
        .minimize => _ = w32.ShowWindow(hwnd, w32.SW_MINIMIZE),
        .maximize => _ = w32.ShowWindow(hwnd, if (w32.IsZoomed(hwnd) != 0) w32.SW_RESTORE else w32.SW_MAXIMIZE),
        .close => _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0),
        else => {},
    }
}

fn trackNonClientMouse(self: *Window) void {
    if (self.tracking_nc_mouse) return;
    var tme = w32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
        .dwFlags = w32.TME_LEAVE | w32.TME_NONCLIENT,
        .hwndTrack = self.hwnd orelse return,
        .dwHoverTime = 0,
    };
    _ = w32.TrackMouseEvent(&tme);
    self.tracking_nc_mouse = true;
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    rect.left += self.sidebarWidth();
    return rect;
}

fn sidebarMode(self: *const Window) bool {
    return !self.is_quick_terminal and self.app.config.@"window-tab-bar-position" == .sidebar;
}

pub const max_collapsed = 32;

pub fn sidebarWidth(self: *const Window) i32 {
    return if (self.sidebarMode()) @intFromFloat(@round(self.sidebar_width * self.scale)) else 0;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}

/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
pub fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithOptions(.{ .context = .tab });
}

pub const AddTabOptions = Surface.InitOptions;

/// Add a tab with per-surface configuration overrides.
pub fn addTabWithOptions(self: *Window, options: AddTabOptions) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    tab_rename.cancelTabRename(self);
    self.frozen_tab_width = null;

    // Tabs without a picked profile belong to the profile `command` runs.
    const list = profiles.detect();
    const with_icon = if (options.icon != null or options.profile_name.len > 0)
        options
    else if (list.selected(self.configuredCommand())) |i|
        self.profileOptions(&list, i, options)
    else
        options;

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.initWithOptions(self.app, self, with_icon);
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees surface

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral(brand.name);
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                _ = w32.ShowWindow(h, w32.SW_SHOW);
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    self.app.saveSession();
    return surface;
}

/// The core may hold the renderer lock during an action. Opening an owned
/// window changes focus and re-enters core handlers, so defer to the loop.
pub fn requestToggleTabOverview(self: *Window) bool {
    if (self.closing or self.is_quick_terminal or self.tab_count == 0) return false;
    return w32.PostMessageW(self.hwnd orelse return false, WM_TOGGLE_TAB_OVERVIEW, 0, 0) != 0;
}

/// Close every split in the selected tab, confirming once if any needs it.
pub fn requestCloseOverviewTab(self: *Window, id: u64) void {
    self.requestCloseTabs(&.{id});
}

/// Whether closing the tab at `index` would kill a running command.
fn tabNeedsConfirm(self: *Window, index: usize) bool {
    var it = self.tab_trees[index].iterator();
    while (it.next()) |entry| {
        if (entry.view.core_surface_ready and entry.view.core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// The id that names the tab at `index` across modal loops, where tab
/// indexes can shift.
pub fn tabId(self: *Window, index: usize) u64 {
    return self.tab_active_surface[index].core_surface.id;
}

fn confirmDialog(owner: ?w32.HWND, message: [*:0]const u16) bool {
    return w32.MessageBoxW(
        owner,
        message,
        std.unicode.utf8ToUtf16LeStringLiteral(brand.name),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    ) == w32.IDOK;
}

/// Close tabs, asking once if any of them is running a command. Tabs are
/// named by surface id because the dialog runs a message loop in which
/// tabs can exit, move, or the window can close.
pub fn requestCloseTabs(self: *Window, ids: []const u64) void {
    const core_app = self.app.core_app;
    const owner_hwnd = self.hwnd;

    const needs_confirmation = for (ids) |id| {
        const index = TabOverview.findTab(self, id) orelse continue;
        if (self.tabNeedsConfirm(index)) break true;
    } else false;
    if (needs_confirmation) {
        const message: [*:0]const u16 = if (ids.len == 1)
            std.unicode.utf8ToUtf16LeStringLiteral("A command is still running in this tab.\nClose the tab and all its splits?")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Commands are still running in some of these tabs.\nClose them anyway?");
        if (!confirmDialog(owner_hwnd, message)) return;
    }

    // Never dereference the old self after the dialog: resolve each tab
    // through its surface again.
    for (ids) |id| {
        const surface = core_app.findSurfaceByID(id) orelse continue;
        const owner = surface.rt_surface.parent_window;
        if (owner.closing or owner.hwnd != owner_hwnd) return;
        owner.closeTabByIndex(TabOverview.findTab(owner, id) orelse continue);
    }
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    tab_rename.cancelTabRename(self);
    var tree = self.tab_trees[idx];
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    // Before `closing` is set: closing the last tab by hand empties the
    // session, unlike closing the window, which keeps it.
    self.app.saveSession();
    if (self.tab_count == 0) {
        self.closing = true;
        self.tab_overview.hide(false);
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}

/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }

    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the surface pointer from the next handle before we modify the tree.
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.layoutSplits();
        if (!self.tab_overview.active) {
            if (ns.hwnd) |h| _ = w32.SetFocus(h);
        }
        self.invalidateTabBar();
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}

/// Switch to the tab at the given index.
/// Set the visibility (occlusion) of every surface in the active tab. Used on
/// window minimize/restore so the renderer stops rebuilding frames while the
/// window is minimized.
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
}

pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    tab_rename.cancelTabRename(self);
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    const surface = self.tab_active_surface[idx];
    var panes = self.tab_trees[idx].iterator();
    while (panes.next()) |entry| entry.view.attention = false;
    self.layoutSplits();
    // An inactive child can exit while the user is searching. Keep focus
    // in the overview; explicit activation hides it before selecting.
    if (!self.tab_overview.active) {
        if (surface.hwnd) |h| _ = w32.SetFocus(h);
    }
    self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(true);
                if (entry.view.hwnd) |h| self.placePane(h, rect);
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            splits.paintDividers(self, dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}

/// Radius of the terminal's top-left corner in the sidebar layout, at 96 DPI.
const terminal_corner = 10.0;

fn terminalCorner(self: *const Window) i32 {
    return if (self.sidebarMode()) @intFromFloat(@round(terminal_corner * self.scale)) else 0;
}

/// Move a pane into place. In the sidebar layout the pane at the
/// terminal's top-left corner is rounded there, like a card.
fn placePane(self: *Window, hwnd: w32.HWND, rect: w32.RECT) void {
    const w = @max(rect.right - rect.left, 1);
    const h = @max(rect.bottom - rect.top, 1);
    // Windows copies the pane's last frame along, so only the newly
    // exposed edge waits for the next one (painted in the terminal's
    // color by its WM_ERASEBKGND) instead of the whole pane going blank.
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, w, h, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);

    const area = self.surfaceRect();
    const r = self.terminalCorner();
    if (r == 0 or rect.left != area.left or rect.top != area.top) {
        _ = w32.SetWindowRgn(hwnd, null, 1);
        return;
    }
    // Windows clips regions without anti-aliasing, so the region drops
    // every pixel the arc only partly covers and paintTerminalCorner
    // blends those pixels from the parent instead.
    const region = w32.CreateRectRgn(0, 0, w, h) orelse return;
    var py: i32 = 0;
    while (py < r) : (py += 1) {
        var first_full: i32 = 0;
        while (first_full < r and canvas_mod.cornerCoverage(first_full, py, r, .{ 1, 1 }) < 1) first_full += 1;
        if (first_full == 0) continue;
        const cut = w32.CreateRectRgn(0, py, first_full, py + 1) orelse continue;
        defer _ = w32.DeleteObject(cut);
        _ = w32.CombineRgn(region, region, cut, w32.RGN_DIFF);
    }
    // The window owns the region from here on.
    if (w32.SetWindowRgn(hwnd, region, 1) == 0) _ = w32.DeleteObject(region);
}

/// Paint the pixels the rounded terminal corner leaves to the parent: a
/// blend of the sidebar's color and the terminal's background by how much
/// of each pixel the arc covers.
fn paintTerminalCorner(self: *Window, hdc_screen: w32.HDC, palette: tab_strip.Palette) void {
    const r = self.terminalCorner();
    if (r == 0) return;
    const area = self.surfaceRect();
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = r, .biHeight = -r } };
    var bits: ?*anyopaque = null;
    const bitmap = w32.CreateDIBSection(mem_dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    const old = w32.SelectObject(mem_dc, bitmap);
    defer {
        _ = w32.SelectObject(mem_dc, old);
        _ = w32.DeleteObject(bitmap);
    }
    const pixels: [*]u32 = @ptrCast(@alignCast(bits orelse return));
    const bg = self.app.config.background;
    const terminal: tab_strip.Rgb = .{ .r = bg.r, .g = bg.g, .b = bg.b };
    var py: i32 = 0;
    while (py < r) : (py += 1) {
        var px_: i32 = 0;
        while (px_ < r) : (px_ += 1) {
            const coverage = canvas_mod.cornerCoverage(px_, py, r, .{ 1, 1 });
            pixels[@intCast(py * r + px_)] = palette.strip.mix(terminal, coverage).toPixel();
        }
    }
    _ = w32.BitBlt(hdc_screen, area.left, area.top, r, r, mem_dc, 0, 0, w32.SRCCOPY);
}

fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            view.setVisible(true);
            if (view.hwnd) |h| self.placePane(h, rect);
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp non-negative before casting
            // so a negative sentinel doesn't panic the @intCast.
            const raw = @backingInt(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}

/// Move the tab containing `surface`, including all of its splits, into a new
/// native window without restarting any child processes.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.is_quick_terminal or self.tab_count <= 1) return false;
    const tab_idx = self.findTabIndex(surface) orelse return false;

    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    destination.init(self.app, .{}) catch |err| {
        alloc.destroy(destination);
        return err;
    };
    errdefer {
        destination.deinit();
        alloc.destroy(destination);
    }

    try self.app.windows.append(alloc, destination);
    var tracked = true;
    errdefer if (tracked) {
        for (self.app.windows.items, 0..) |window, i| {
            if (window == destination) {
                _ = self.app.windows.orderedRemove(i);
                break;
            }
        }
    };

    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    var moved_tree = self.tab_trees[tab_idx];

    // Move child HWNDs and owned popups before mutating either tab array.
    try reparentTabWindows(&moved_tree, self.hwnd.?, destination_hwnd);

    const moved_active = self.tab_active_surface[tab_idx];
    const moved_title = self.tab_titles[tab_idx];
    const moved_title_len = self.tab_title_lens[tab_idx];

    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }

    destination.tab_trees[0] = moved_tree;
    destination.tab_active_surface[0] = moved_active;
    destination.tab_titles[0] = moved_title;
    destination.tab_title_lens[0] = moved_title_len;
    destination.tab_count = 1;
    destination.active_tab = 0;

    var it = destination.tab_trees[0].iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;

    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.invalidateTabBar();

    destination.updateTabBarVisibility();
    destination.updateWindowTitle();
    _ = w32.ShowWindow(destination_hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(destination_hwnd);
    destination.layoutSplits();
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);

    tracked = false;
    return true;
}

fn reparentTabWindows(tree: *const SplitTree(Surface), source: w32.HWND, destination: w32.HWND) !void {
    var moved: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        entry.view.reparentNativeWindows(destination) catch |err| {
            var rollback = tree.iterator();
            for (0..moved) |_| {
                rollback.next().?.view.reparentNativeWindows(source) catch |rollback_err| {
                    log.err("tab window transfer rollback failed: {}", .{rollback_err});
                };
            }
            return err;
        };
        moved += 1;
    }
}

test "detached tab rolls back child and popup transfers" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const source = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(source);
    const destination = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(destination);

    const first = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(first);
    const second = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(second);
    for ([_]*Surface{ first, second }) |surface| {
        surface.* = .{ .app = undefined };
        surface.hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_CHILD, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
        surface.search_hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_POPUP, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
    }
    // Fail after moving the first complete surface and the second surface's
    // child/search popup, exercising both levels of transaction rollback.
    second.palette_hwnd = @ptrFromInt(1);
    const nodes = [_]SplitTree(Surface).Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @fromBackingInt(1), .right = @fromBackingInt(2) } },
        .{ .leaf = first },
        .{ .leaf = second },
    };
    const tree: SplitTree(Surface) = .{ .arena = undefined, .nodes = &nodes, .zoomed = null };
    try testing.expectError(error.Win32Error, reparentTabWindows(&tree, source, destination));
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, source), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(source))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }

    second.palette_hwnd = null;
    try reparentTabWindows(&tree, source, destination);
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, destination), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(destination))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }
}

/// Update the top-level window title to match the active tab's title.
pub fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.window_title_override_len orelse
        self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    if (self.window_title_override_len != null) {
        @memcpy(buf[0..len], self.window_title_override[0..len]);
    } else {
        @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    }
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Set or clear the explicit top-level window title override.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        self.window_title_override_len = @intCast(wide_string.fromUtf8(&self.window_title_override, title));
    }
    self.updateWindowTitle();
}

/// Called when a tab's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    var wbuf: [256]u16 = undefined;
    const len: u16 = @intCast(wide_string.fromUtf8(&wbuf, title));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        // When the strip is the title bar, hiding a lone tab saves no space.
        .auto => self.tab_count > 1 or self.integratedTitleBar(),
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_overview.active and !self.overview_refresh_pending) {
        self.overview_refresh_pending = w32.PostMessageW(hwnd, WM_REFRESH_TAB_OVERVIEW, 0, 0) != 0;
    }
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
    if (self.sidebarMode()) {
        var side = workspace.sidebarRect(self);
        _ = w32.InvalidateRect(hwnd, &side, 0);
        const area = self.surfaceRect();
        const r = self.terminalCorner();
        var corner_rect: w32.RECT = .{ .left = area.left, .top = area.top, .right = area.left + r, .bottom = area.top + r };
        _ = w32.InvalidateRect(hwnd, &corner_rect, 0);
    }
}

/// Paint the tab strip into an offscreen 32-bit DIB, so hover changes
/// don't flicker and the strip can blend its anti-aliased shapes directly.
fn paintTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    const layout = self.stripLayout();
    const height = layout.height();
    if (height <= 0 or layout.width <= 0) return;

    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    // A negative height makes the DIB top-down, so row 0 is the top.
    const info: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = layout.width, .biHeight = -height } };
    var bits: ?*anyopaque = null;
    const mem_bmp = w32.CreateDIBSection(mem_dc, &info, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    var palette: tab_strip.Palette = .fromTerminal(.{ .r = bg.r, .g = bg.g, .b = bg.b }, .{ .r = fg.r, .g = fg.g, .b = fg.b });
    // The settings panel dims the terminal; the active tab is part of the
    // same surface, so it dims with it.
    if (self.settings_panel != null) {
        palette.active_tab = palette.active_tab.mix(tab_strip.Rgb.black, @as(f32, SettingsPanel.backdrop_alpha) / 255);
    }
    tab_strip.paint(
        .{ .hdc = mem_dc, .pixels = @ptrCast(@alignCast(bits orelse return)), .width = layout.width, .height = height },
        layout,
        palette,
        self.strip_fonts,
        .{
            .text = self.tab_titles[0..self.tab_count],
            .lens = self.tab_title_lens[0..self.tab_count],
            .icons = icons: {
                var icons: [MAX_TABS]?w32.HICON = undefined;
                for (0..self.tab_count) |i| icons[i] = self.tabIcon(i);
                break :icons icons[0..self.tab_count];
            },
        },
        .{
            .hover = self.strip_hover,
            // The gear stays lit while its panel is open.
            .pressed = if (self.settings_panel != null) .settings else self.strip_pressed,
            .window_active = self.window_active,
            .maximized = w32.IsZoomed(hwnd) != 0,
        },
    );
    _ = w32.BitBlt(hdc_screen, 0, 0, layout.width, height, mem_dc, 0, 0, w32.SRCCOPY);
    if (self.sidebarMode()) {
        workspace.paintSidebar(self, hdc_screen, palette);
        self.paintTerminalCorner(hdc_screen, palette);
    }
}

/// Honor a program's CSI 8 t resize only when it owns the whole window.
/// Changing the outer dimensions by the surface-size delta accounts for
/// non-client borders without assuming a particular decoration or DPI.
pub fn resizeSurface(self: *Window, surface: *Surface, size: apprt.action.ResizeWindow) bool {
    const hwnd = self.hwnd orelse return false;
    if (self.closing or self.is_quick_terminal or self.is_fullscreen or
        w32.IsZoomed(hwnd) != 0 or w32.IsIconic(hwnd) != 0) return false;
    if (self.tab_count != 1 or self.tab_trees[0].isSplit() or
        self.tab_active_surface[0] != surface) return false;
    const surface_hwnd = surface.hwnd orelse return false;
    var outer: w32.RECT = undefined;
    var client: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &outer) == 0 or
        w32.GetClientRect(surface_hwnd, &client) == 0) return false;

    // The surface's drawable width excludes a reserved (non-overlay)
    // scrollbar strip; the child HWND's client rectangle does not.
    const current = surface.getSize() catch return false;
    var width = resizedDimension(size.width, surface.scale, @intCast(current.width), outer.right - outer.left);
    var height = resizedDimension(size.height, surface.scale, @intCast(current.height), outer.bottom - outer.top);
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0) {
        if (size.width > 0) width = @min(width, monitor.rcWork.right - monitor.rcWork.left);
        if (size.height > 0) height = @min(height, monitor.rcWork.bottom - monitor.rcWork.top);
    }
    return w32.SetWindowPos(hwnd, null, 0, 0, width, height, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE) != 0;
}

fn resizedDimension(requested: u32, scale: f32, current: i32, outer: i32) i32 {
    if (requested == 0) return outer;
    // Bound untrusted terminal requests before converting back to Win32's
    // signed dimensions. Larger sizes are not useful desktop window sizes.
    const px = @min(@as(f64, @floatFromInt(requested)) * scale, 32_767);
    return @max(1, outer - current + @as(i32, @intFromFloat(@ceil(px))));
}

test "program resize preserves zero dimensions and scales points" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 816), resizedDimension(0, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 916), resizedDimension(600, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 516), resizedDimension(500, 1, 800, 816));
    try testing.expectEqual(@as(i32, 32_783), resizedDimension(std.math.maxInt(u32), 2, 800, 816));
}

test "program resize native window guards and zero dimensions" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("");
    // Hidden system-class windows need neither a renderer nor an application.
    const hwnd = w32.CreateWindowExW(0, class, title, w32.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    const child = w32.CreateWindowExW(0, class, title, w32.WS_CHILD, 0, 0, 200, 100, hwnd, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(child);
    var surface: Surface = undefined;
    surface.hwnd = child;
    surface.scale = 1;
    // Simulate a 20-pixel scrollbar reservation within the 200-pixel child.
    surface.width = 180;
    surface.height = 100;
    var window: Window = .{ .app = undefined, .hwnd = hwnd, .tab_count = 1 };
    window.tab_active_surface[0] = &surface;
    window.tab_trees[0] = .{ .arena = undefined, .nodes = &.{.{ .leaf = &surface }}, .zoomed = null };

    var before: w32.RECT = undefined;
    var after: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(hwnd, &before) != 0);
    try testing.expect(window.resizeSurface(&surface, .{ .width = 220, .height = 0 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left + 40, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top, after.bottom - after.top);
    before = after;
    try testing.expect(window.resizeSurface(&surface, .{ .width = 0, .height = 120 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top + 20, after.bottom - after.top);

    window.is_fullscreen = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_fullscreen = false;
    window.is_quick_terminal = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_quick_terminal = false;
    window.tab_count = 2;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.tab_count = 1;
    window.tab_trees[0].nodes = &.{.{ .split = undefined }};
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    // Flip the flag first: the SWP_FRAMECHANGED below runs WM_NCCALCSIZE,
    // which must already see the new state to pick the right frame.
    self.is_fullscreen = !self.is_fullscreen;
    if (self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.updateTabBarVisibility();
    self.handleResize();
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    // With or without a caption the strip changes role, and possibly height.
    self.updateTabBarVisibility();
    self.handleResize();
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint tab bar.
/// Timer id used to auto-hide the resize overlay.
const RESIZE_OVERLAY_TIMER_ID: usize = 0x5247; // 'RG'
/// Polls tabs for SSH sessions, and refreshes the sidebar's "opened 5m
/// ago" ages once a minute.
const SIDEBAR_TIMER_ID: usize = 0x5341; // 'SA'
const SIDEBAR_TIMER_MS = 3_000;

pub fn handleResize(self: *Window) void {
    if (self.settings_panel) |panel| panel.place(self.settingsArea());
    self.layoutSplits();
    self.invalidateTabBar();
    self.showResizeOverlay();
}

/// Show the transient "columns × rows" overlay during a resize, honoring
/// the resize-overlay / -position / -duration config. Auto-hides via a
/// timer that each subsequent resize re-arms.
fn showResizeOverlay(self: *Window) void {
    switch (self.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.resize_seen_first) {
            // Suppress for the initial layout pass at window creation.
            self.resize_seen_first = true;
            return;
        },
        .always => {},
    }
    self.resize_seen_first = true;
    const hwnd = self.hwnd orelse return;

    // Grid dimensions from the active surface.
    const surface = self.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();

    var buf8: [32]u8 = undefined;
    const text8 = std.mem.print(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;

    if (self.resize_overlay_hwnd == null) {
        self.resize_overlay_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            self.app.hinstance,
            null,
        );
        if (self.resize_overlay_hwnd) |h| {
            if (self.strip_fonts.title) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.resize_overlay_hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));

    // Position within the client area per resize-overlay-position.
    const s = self.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (self.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, self.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, RESIZE_OVERLAY_TIMER_ID, dur_ms, null);
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    switch (self.stripLayout().hitTest(x, y)) {
        .new_tab => _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .tab_close => |i| self.closeTabFromStrip(i),
        .settings => self.openSettings(),
        .new_tab_menu => self.showNewTabMenu(),
        .tab => |i| {
            self.selectTabIndex(i);
            // Start tracking potential tab drag
            self.drag_tab = @intCast(i);
            self.drag_start_x = x;
            self.drag_active = false;
            if (self.hwnd) |h| _ = w32.SetCapture(h);
            self.invalidateTabBar();
        },
        else => {},
    }
}

/// Open the settings panel over the terminal, or focus it if it is open.
pub fn openSettings(self: *Window) void {
    if (self.settings_panel) |panel| return panel.focus();
    const hwnd = self.hwnd orelse return;
    const alloc = self.app.core_app.alloc;
    const panel = alloc.create(SettingsPanel) catch return;
    panel.* = .{
        .owner = hwnd,
        .host = .{
            .ctx = self,
            .reload = settingsReload,
            .edit_file = settingsEditFile,
            .colors = settingsColors,
            .closed = settingsClosed,
        },
        .alloc = alloc,
        .scale = self.scale,
    };
    self.settings_panel = panel;
    self.invalidateTabBar();
    panel.open(self.app.hinstance, self.settingsArea()) catch |err| {
        log.err("failed to open settings: {}", .{err});
        self.settings_panel = null;
        alloc.destroy(panel);
    };
}

/// The text of the configured `command`, as profiles compare it.
pub fn configuredCommand(self: *Window) ?[]const u8 {
    const command = self.app.config.command orelse return null;
    return switch (command) {
        .shell => |text| text,
        .direct => |argv| if (argv.len > 0) argv[0] else null,
    };
}

pub fn tabIconSize(self: *const Window) i32 {
    return @intFromFloat(@round(16 * self.scale));
}

/// Tab options for installed profile `index`: its icon, name and section.
/// The name points into `list`, which must outlive the surface's init.
fn profileOptions(self: *Window, list: *const profiles.List, index: usize, base: AddTabOptions) AddTabOptions {
    var options = base;
    options.icon = self.app.profile_icons.get(list.icon(index), self.tabIconSize());
    options.profile_name = list.name(index);
    options.wsl = list.items[index].source == .wsl;
    return options;
}

/// A tab shows the icon of the first of its panes that has one.
pub fn tabIcon(self: *Window, index: usize) ?w32.HICON {
    var it = self.tab_trees[index].iterator();
    while (it.next()) |entry| {
        if (entry.view.icon) |icon| return icon;
    }
    return null;
}

/// Open installed profile `index` in a new tab, or a new window. Indexes
/// past the last profile do nothing, as in Windows Terminal.
pub fn openProfile(self: *Window, index: usize, new_window: bool) void {
    const list = profiles.detect();
    self.openProfileIn(&list, index, null, new_window);
}

/// Open profile `index` of `list`, in `folder` when given.
pub fn openProfileIn(self: *Window, list: *const profiles.List, index: usize, folder: ?[]const u8, new_window: bool) void {
    if (index >= list.len) return;
    const alloc = self.app.core_app.alloc;
    // The surface copies the command into its own config during init.
    const text = alloc.dupeSentinel(u8, list.command(index), 0) catch return;
    defer alloc.free(text);
    const command: configpkg.Command = .{ .shell = text };
    const options = self.profileOptions(list, index, .{
        .context = if (new_window) .window else .tab,
        .command = &command,
        .working_directory = folder,
    });
    if (new_window) {
        self.app.openWindowWithTab(options) catch |err| log.err("failed to open {s} in a new window: {}", .{ list.name(index), err });
        return;
    }
    _ = self.addTabWithOptions(options) catch |err| log.err("failed to open {s}: {}", .{ list.name(index), err });
}

/// Drop the profile menu below the arrow beside "+". Shift+click opens the
/// profile in a new window, as in Windows Terminal.
fn showNewTabMenu(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const arrow = self.stripLayout().newTabMenuRect();
    var corner: w32.POINT = .{ .x = arrow.left, .y = arrow.bottom + @as(i32, @intFromFloat(@round(4 * self.scale))) };
    _ = w32.ClientToScreen(hwnd, &corner);
    const list = profiles.detect();

    self.strip_pressed = .new_tab_menu;
    self.invalidateTabBar();
    const pick = new_tab_menu.show(hwnd, corner, &list, list.selected(self.configuredCommand()), &self.app.profile_icons, self.scale, self.menusDark());
    self.strip_pressed = .none;
    self.invalidateTabBar();

    const index = pick orelse return;
    self.openProfile(index, w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0);
}

/// The terminal area below the strip, in screen pixels, which the
/// settings panel covers.
fn settingsArea(self: *Window) w32.RECT {
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const hwnd = self.hwnd orelse return client;
    _ = w32.GetClientRect(hwnd, &client);
    var top_left: w32.POINT = .{ .x = 0, .y = self.tabBarHeight() };
    var bottom_right: w32.POINT = .{ .x = client.right, .y = client.bottom };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

fn settingsReload(ctx: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    _ = actions.performAction(self.app, .app, .reload_config, .{ .soft = false }) catch |err| {
        log.err("failed to reload config: {}", .{err});
    };
}

fn settingsEditFile(ctx: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    _ = self.app.openConfigFile(.os_open);
}

fn settingsColors(ctx: *anyopaque) [2]tab_strip.Rgb {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    return .{ .{ .r = bg.r, .g = bg.g, .b = bg.b }, .{ .r = fg.r, .g = fg.g, .b = fg.b } };
}

fn settingsClosed(ctx: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const panel = self.settings_panel orelse return;
    self.settings_panel = null;
    self.app.core_app.alloc.destroy(panel);
    self.invalidateTabBar();
}

/// Closing with the mouse keeps the other tabs at their width, as Chrome
/// does, so the next close button lands under the pointer. The width is
/// released once the pointer leaves the tabs.
fn closeTabFromStrip(self: *Window, index: usize) void {
    self.frozen_tab_width = self.stripLayout().tabWidth();
    self.requestCloseTabs(&.{self.tabId(index)});
}

fn releaseFrozenTabWidth(self: *Window) void {
    if (self.frozen_tab_width == null) return;
    self.frozen_tab_width = null;
    self.invalidateTabBar();
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    tab_rename.cancelTabRename(self);

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;

    self.active_tab = to;
    self.invalidateTabBar();
    self.app.saveSession();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    self.trackMouseLeave();
    const part = self.stripLayout().hitTest(x, y);
    self.setStripHover(part);
    switch (part) {
        .tab, .tab_close => {},
        else => self.releaseFrozenTabWidth(),
    }
}

/// Ask for WM_MOUSELEAVE, which clears hover in the strip and sidebar.
fn trackMouseLeave(self: *Window) void {
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    const clicked_tab: ?usize = switch (self.stripLayout().hitTest(x, y)) {
        .tab, .tab_close => |i| i,
        else => null,
    };
    self.showTabMenu(clicked_tab, x, y);
}

/// Native menus follow the terminal's background, light or dark.
pub fn menusDark(self: *const Window) bool {
    const bg = self.app.config.background;
    return tab_strip.Rgb.isDark(.{ .r = bg.r, .g = bg.g, .b = bg.b });
}

/// The tab right-click menu at client point (x, y).
fn showTabMenu(self: *Window, clicked_tab: ?usize, x: i16, y: i16) void {

    // If clicked on empty area (not a tab), only show "New Tab".
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    menu_theme.apply(self.menusDark());

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.requestCloseTabs(&.{self.tabId(tab)});
        },
        TAB_CTX_CLOSE_OTHERS, TAB_CTX_CLOSE_RIGHT => {
            const tab = clicked_tab orelse return;
            const first = if (cmd == TAB_CTX_CLOSE_RIGHT) tab + 1 else 0;
            var ids: [MAX_TABS]u64 = undefined;
            var count: usize = 0;
            for (first..self.tab_count) |i| {
                if (i == tab) continue;
                ids[count] = self.tabId(i);
                count += 1;
            }
            self.requestCloseTabs(ids[0..count]);
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    self.releaseFrozenTabWidth();
    workspace.setSidebarHover(self, .none);
    // Caption buttons are tracked by WM_NCMOUSELEAVE instead.
    if (!self.strip_hover.isCaptionButton()) self.setStripHover(.none);
}

/// Return true if it is safe to close this whole window. If any tab still
/// has a running process, show a single aggregate confirmation dialog
/// (mirroring macOS/GTK, which confirm once per window) and return whether
/// the user approved. Whole-window close paths (title-bar X, Alt+F4,
/// close_window) previously skipped this check entirely; the per-surface
/// close path (Ctrl+Shift+W) still confirms separately in Surface.close.
/// When the last tab has already been closed (tab_count == 0) there is
/// nothing to confirm, so this returns true silently.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    const needs = for (0..self.tab_count) |i| {
        if (self.tabNeedsConfirm(i)) break true;
    } else false;
    if (!needs) return true;
    return confirmDialog(self.hwnd, std.unicode.utf8ToUtf16LeStringLiteral(
        "Commands are still running in this window.\nClose anyway?",
    ));
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    // Closing the window keeps its tabs in the session; see saveSession.
    self.closing = true;
    self.app.saveSession();
    self.tab_overview.deinit();
    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;
    self.tab_overview.deinit();

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        self.strip_fonts.deinit();
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    self.strip_fonts.deinit();
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MBUTTONUP,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        WM_TOGGLE_TAB_OVERVIEW => {
            window.tab_overview.toggle(window) catch |err| {
                log.warn("unable to open tab overview err={}", .{err});
            };
            return 0;
        },
        WM_REFRESH_TAB_OVERVIEW => {
            window.overview_refresh_pending = false;
            window.tab_overview.refresh();
            return 0;
        },
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (wparam == SearchField.caret_timer) {
                if (workspace.sidebarField(window)) |field| field.blink();
                window.invalidateTabBar();
                return 0;
            }
            if (wparam == SIDEBAR_TIMER_ID) {
                if (window.sidebarMode()) {
                    workspace.refreshServers(window);
                    window.sidebar_ticks +%= 1;
                    if (window.sidebar_ticks % (60_000 / SIDEBAR_TIMER_MS) == 0) window.invalidateTabBar();
                }
                return 0;
            }
            if (wparam == RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, RESIZE_OVERLAY_TIMER_ID);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark theming for the STATIC popups owned by this window
            // (hovered-URL link preview, resize overlay). Static controls
            // send this to their owner, i.e. here — not to surfaceWndProc.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(true);
            }
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            // After system sleep/resume nothing else kicks a re-present:
            // the renderer has no vsync/power awareness, so without this
            // the last pre-sleep frame can stay on screen stale (the same
            // bug as microsoft/terminal#14483). Invalidate every surface
            // in the active tab; the surface WM_PAINT handler validates
            // and wakes the renderer thread, driving a full re-present
            // through the existing pipeline. Both resume events may
            // arrive for a single resume; the redundant invalidation is
            // harmless. Return TRUE per the message contract.
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                if (window.active_tab < window.tab_count) {
                    var it = window.tab_trees[window.active_tab].iterator();
                    while (it.next()) |entry| {
                        if (entry.view.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                    }
                }
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            if (window.settings_panel) |panel| panel.place(window.settingsArea());
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            // Title-bar X / Alt+F4 / close_all_windows land here. Confirm
            // once for the whole window if any tab has a running process.
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintTabBar();
            return 0;
        },
        w32.WM_NCCALCSIZE => {
            if (wparam != 0 and window.integratedTitleBar()) {
                return window.calcClientArea(hwnd, wparam, lparam);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCHITTEST => {
            if (window.integratedTitleBar()) return window.hitTestFrame(hwnd, lparam);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // Caption buttons are drawn by the tab strip. DefWindowProc would
        // paint the classic buttons over them, so it never sees their
        // mouse messages.
        w32.WM_NCMOUSEMOVE => {
            const button = captionButtonAt(wparam);
            window.trackNonClientMouse();
            window.setStripHover(button orelse .none);
            if (button != null) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCMOUSELEAVE => {
            window.tracking_nc_mouse = false;
            window.strip_pressed = .none;
            if (window.strip_hover.isCaptionButton()) window.setStripHover(.none);
            return 0;
        },
        w32.WM_NCLBUTTONDOWN => {
            if (captionButtonAt(wparam)) |button| {
                window.strip_pressed = button;
                window.invalidateTabBar();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCLBUTTONUP => {
            const pressed = window.strip_pressed;
            window.strip_pressed = .none;
            if (captionButtonAt(wparam)) |button| {
                window.invalidateTabBar();
                if (pressed.eql(button)) window.pressCaptionButton(button);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCLBUTTONDBLCLK => {
            if (captionButtonAt(wparam) != null) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_DPICHANGED => {
            // Per-monitor DPI: rescale the strip and take the size Windows
            // suggests for the new monitor.
            window.scale = @as(f32, @floatFromInt((wparam >> 16) & 0xFFFF)) / 96.0;
            window.loadStripFonts();
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
            );
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == tab_rename.RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                tab_rename.finishTabRename(window);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_KEYDOWN => {
            if (window.sidebar_search.focused) {
                workspace.sidebarKey(window, @truncate(wparam));
                return 0;
            }
            if (window.server_field.focused) {
                workspace.serverFieldKey(window, @truncate(wparam));
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CHAR => {
            if (window.sidebar_search.focused and window.sidebar_search.typeChar(@truncate(wparam))) {
                window.sidebar_scroll = 0;
                window.invalidateTabBar();
            } else if (window.server_field.focused and window.server_field.typeChar(@truncate(wparam))) {
                window.invalidateTabBar();
            }
            return 0;
        },
        w32.WM_KILLFOCUS => {
            // Clicking the terminal moves the keyboard away from the boxes.
            if (workspace.sidebarField(window)) |field| {
                field.focus(hwnd, false);
                window.server_field.clear();
                window.invalidateTabBar();
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEWHEEL => {
            var pt: w32.POINT = .{ .x = @as(i16, @truncate(lparam & 0xFFFF)), .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)) };
            _ = w32.ScreenToClient(hwnd, &pt);
            if (workspace.inSidebar(window, pt.x, pt.y)) {
                const notches: i32 = @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16))));
                workspace.scrollSidebar(window, -@divTrunc(notches * @as(i32, @intFromFloat(@round(48 * window.scale))), 120));
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // The sidebar's text boxes keep the keyboard on this window.
            if (workspace.sidebarField(window) != null) return 0;
            // Forward keyboard focus to the active child surface.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the terminal.
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| _ = w32.SetFocus(h);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => {
            // A growing window exposes area its panes haven't reached yet,
            // and splits leave gaps: give them the terminal's color rather
            // than whatever was on screen. The strip and sidebar paint
            // themselves in WM_PAINT, double-buffered, so they're left out.
            if (window.app.bg_brush) |brush| {
                const area = window.surfaceRect();
                _ = w32.FillRect(@ptrFromInt(wparam), &area, brush);
            }
            return 1;
        },
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (splits.hitTestDivider(window, x, y)) |hit| {
                splits.startDividerDrag(window, hit.handle, hit.layout);
                return 0;
            }
            if (workspace.inSidebar(window, x, y)) {
                workspace.sidebarClick(window, x, y);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                splits.endDividerDrag(window);
                return 0;
            }
            if (window.sidebar_resizing) {
                window.sidebar_resizing = false;
                _ = w32.ReleaseCapture();
                window.app.saveSession();
                return 0;
            }
            if (window.sidebar_drag != null) {
                const moved = window.sidebar_dragging;
                window.sidebar_drag = null;
                window.sidebar_dragging = false;
                _ = w32.ReleaseCapture();
                window.invalidateTabBar();
                if (moved) window.app.saveSession();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click on tab bar starts inline rename
            if (y < window.tabBarHeight()) {
                switch (window.stripLayout().hitTest(x, y)) {
                    .tab => |i| tab_rename.startTabRename(window, i),
                    else => {},
                }
                return 0;
            }
            if (splits.hitTestDivider(window, x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            switch (workspace.sidebarTarget(window, x, y)) {
                .tab, .close => |i| {
                    window.showTabMenu(i, x, y);
                    return 0;
                },
                .none, .search, .resize, .group, .group_new, .group_menu, .section, .section_new, .section_menu, .server_field => {},
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MBUTTONUP => {
            // Middle-click closes a tab, as in browsers.
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            switch (window.stripLayout().hitTest(x, y)) {
                .tab, .tab_close => |i| window.closeTabFromStrip(i),
                else => {},
            }
            switch (workspace.sidebarTarget(window, x, y)) {
                .tab, .close => |i| window.requestCloseTabs(&.{window.tabId(i)}),
                .none, .search, .resize, .group, .group_new, .group_menu, .section, .section_new, .section_menu, .server_field => {},
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                splits.updateDividerDrag(window, x, y);
                return 0;
            }
            if (window.sidebar_resizing) {
                const width = std.math.clamp(@as(f32, @floatFromInt(x)) / window.scale, tab_sidebar.min_width, tab_sidebar.max_width);
                if (width != window.sidebar_width) {
                    window.sidebar_width = width;
                    window.handleResize();
                    // Mouse moves keep coming during the drag, and WM_PAINT
                    // waits for a quiet queue, so the sidebar would lag.
                    _ = w32.UpdateWindow(hwnd);
                }
                return 0;
            }
            if (window.sidebar_drag) |from| {
                if (!window.sidebar_dragging and @abs(y - window.sidebar_drag_y) > @as(i32, @intFromFloat(5 * window.scale))) {
                    window.sidebar_dragging = true;
                    window.invalidateTabBar();
                }
                if (window.sidebar_dragging) {
                    // Tabs move within their folder; the folder decides the group.
                    switch (workspace.sidebarTarget(window, x, y)) {
                        .tab => |to| if (to != from and tab_sidebar.sameGroup(workspace.groupKey(window, from), workspace.groupKey(window, to))) {
                            window.moveTabTo(from, to);
                            window.sidebar_drag = to;
                            _ = w32.UpdateWindow(hwnd);
                        },
                        else => {},
                    }
                }
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.tab_count > 1) {
                    const from: usize = @intCast(window.drag_tab);
                    const target = window.stripLayout().dropIndex(x);
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            } else {
                window.releaseFrozenTabWidth();
                if (workspace.inSidebar(window, x, y)) window.trackMouseLeave();
            }
            workspace.setSidebarHover(window, workspace.sidebarTarget(window, x, y));
            return 0;
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.sidebar_resizing or workspace.sidebarTarget(window, pt.x, pt.y) == .resize) {
                    if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| _ = w32.SetCursor(cursor);
                    return 1;
                }
                if (splits.hitTestDivider(window, pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            window.window_active = activated != w32.WA_INACTIVE;
            window.invalidateTabBar();
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
