//! Win32 application runtime. Manages the Win32 window class, message loop,
//! and surface (window) lifecycle.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
pub const Config = configpkg.Config;

/// The config from its files, with Sharp's background style and clipboard
/// keys applied.
pub fn loadConfig(alloc: std.mem.Allocator) !Config {
    var config = try Config.load(alloc);
    background_style.apply(&config);
    clipboard_keys.apply(&config);
    return config;
}
const CoreApp = @import("../../App.zig");
const internal_os = @import("../../os/main.zig");
const global = @import("../../global.zig");

const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const TabOverview = @import("TabOverview.zig");
const SettingsPanel = @import("SettingsPanel.zig");
const canvas = @import("canvas.zig");
const profiles = @import("profiles.zig");
const session = @import("session.zig");
const servers = @import("servers.zig");
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const UntrustedUrl = @import("UntrustedUrl.zig");
const wide_string = @import("wide_string.zig");

pub const OpenUrlRequest = struct {
    kind: apprt.action.OpenUrl.Kind,
    url: []u8,

    pub fn deinit(self: *OpenUrlRequest, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.destroy(self);
    }
};

const input = @import("../../input.zig");
const find_bar = @import("find_bar.zig");
const command_palette = @import("command_palette.zig");
const workspace = @import("workspace.zig");
const tab_rename = @import("tab_rename.zig");
const actions = @import("actions.zig");
const pane_messages = @import("pane_messages.zig");
const window_messages = @import("window_messages.zig");
const global_hotkey = @import("global_hotkey.zig");
const background_style = @import("background_style.zig");
const clipboard_keys = @import("clipboard_keys.zig");
const updater = @import("updater.zig");
const browser_remote = @import("browser_remote.zig");
const mcp_server = @import("mcp_server.zig");
const default_terminal = @import("default_terminal.zig");
const terminal_handoff = @import("terminal_handoff.zig");

comptime {
    // Exports the exe's load configuration; nothing references it.
    _ = @import("load_config.zig");
}

/// A registered global system hotkey: the RegisterHotKey id and the binding
/// action to perform when WM_HOTKEY delivers that id.
const GlobalHotkey = struct { id: i32, action: input.Binding.Action };

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// The core holds the renderer lock during open_url, and ShellExecuteW pumps
/// messages whose handlers take that lock, so the URL is opened later.
pub const WM_APP_OPEN_URL: u32 = w32.WM_APP + 4;

/// Posted by ai_usage.zig's thread when it has read new usage.
pub const WM_APP_AI_USAGE: u32 = w32.WM_APP + 5;

/// Posted by updater.zig's thread when an update's state changes.
pub const WM_APP_UPDATE: u32 = w32.WM_APP + 7;

/// Posted by terminal_handoff.zig when Windows hands Sharp a console.
const WM_APP_HANDOFF: u32 = w32.WM_APP + 8;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Window");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Terminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_TIMER).
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Msg");

/// The core application.
core_app: *CoreApp,

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atoms from RegisterClassExW.
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
overview_class_atom: u16 = 0,
settings_class_atom: u16 = 0,

/// JetBrains Mono registered for Sharp's own UI; see canvas.zig.
ui_fonts: canvas.EmbeddedFonts = .{ null, null },

/// Shell profile icons shown on tabs and in the profile menu.
profile_icons: profiles.Icons = .{},

/// Set while reopening saved tabs, so they don't rewrite the session one
/// at a time.
restoring_session: bool = false,

/// SSH servers connected to, offered by the sidebar's Servers menu.
recent_servers: servers.Recent = .{},
msg_class_atom: u16 = 0,

/// List of active Window containers (tabbed windows).
windows: std.ArrayList(*Window) = .empty,

/// Background brush created from the configured background color.
/// Used by WM_ERASEBKGND to fill exposed areas during resize,
/// matching the terminal background so the flash is invisible.
bg_brush: ?w32.HBRUSH = null,

/// Quit timer state, mirroring GTK's three-state approach:
/// - off: no quit pending
/// - active: timer is running (waiting for delay to expire)
/// - expired: delay has elapsed, quit on next tick
quit_timer_state: enum { off, active, expired } = .off,

/// Whether quit has been requested.
quit_requested: bool = false,

/// The quick terminal instance (if active).
quick_terminal: ?*QuickTerminal = null,

/// Registered global system hotkeys (RegisterHotKey). Maps the id delivered in
/// WM_HOTKEY back to the binding action to perform. Generalized from the old
/// single quick-terminal hotkey to every keybind flagged `global:`.
global_hotkeys: std.ArrayList(GlobalHotkey) = .empty,

/// Cached ITaskbarList3 for taskbar-button progress (OSC 9;4), created lazily
/// on first progress_report. Null until then / if COM creation fails.
taskbar: ?*w32.ITaskbarList3 = null,

/// Core surface id of the surface that produced the current desktop
/// notification balloon; a balloon click focuses it. 0 = app-targeted.
/// A single id suffices: there is one NOTIF_DESKTOP_UID tray balloon and
/// each new notification overwrites it.
notif_desktop_surface_id: u64 = 0,
/// Whether CoInitializeEx has been called on the main thread.
com_initialized: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = loadConfig(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    // Create a brush matching the configured background color so that
    // any exposed window area during resize matches the terminal
    // background, making the flash invisible.
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
    };

    // Register the window container class (GDI painting, no CS_OWNDC).
    // CS_DBLCLKS is required to receive WM_LBUTTONDBLCLK for divider equalize.
    // Application icon, loaded from the embedded resource. Falls back
    // to the default app icon if missing (only happens with unusual
    // build configs that strip the .rc file).
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &window_messages.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };

    // Register the terminal surface class (OpenGL via WGL, needs CS_OWNDC).
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &pane_messages.surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };

    self.overview_class_atom = try TabOverview.registerClass(hinstance);
    self.settings_class_atom = try SettingsPanel.registerClass(hinstance);
    self.ui_fonts = canvas.loadEmbeddedFonts();
    errdefer _ = w32.UnregisterClassW(TabOverview.class_name, hinstance);

    // Register the message-only window class (WM_APP_WAKEUP, WM_TIMER).
    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };

    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(brand.name ++ "Msg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;

    // Store self pointer in msg_hwnd's GWLP_USERDATA for msgWndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Register global hotkey for quick terminal (if configured).
    global_hotkey.registerGlobalHotkey(self);

    self.configureUpdater();
    self.configureDefaultTerminal(false);

    // Claude's browser tools, only while the browser is switched on.
    browser_remote.target = self.msg_hwnd;
    mcp_server.setEnabled(self.config.@"ai-tools-browser");

    // Builds without Zig's segfault handler (ReleaseFast) crash through
    // here; the handler and panics are covered in main_ghostty.zig.
    _ = w32.SetUnhandledExceptionFilter(&crashFilter);
}

/// A crash ends the console programs the tabs started, as closing them
/// would, then lets Windows report it as usual.
fn crashFilter(_: *anyopaque) callconv(.winapi) c_long {
    internal_os.console_programs.endAll();
    return w32.EXCEPTION_CONTINUE_SEARCH;
}

pub fn run(self: *App) !void {
    // Create the initial Window container with one tab.
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, .{});
    try self.windows.append(alloc, window);
    const restored = self.restoreSession(window) catch |err| restored: {
        log.err("failed to restore the session: {}", .{err});
        break :restored false;
    };
    // Started by Windows for a console: that console is the first tab. The
    // quit armed at startup, which a first tab disarms, waits for it.
    if (!restored) {
        if (terminal_handoff.launchedByWindows()) {
            self.stopQuitTimer();
            if (self.msg_hwnd) |hwnd| {
                _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, 30_000, null);
                self.quit_timer_state = .active;
            }
        } else _ = try window.addTab();
    }

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    loop: while (true) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT received. Check if it's still wanted — stopQuitTimer()
            // resets quit_requested if a new surface opened after
            // PostQuitMessage was called (e.g. during startup).
            // GetMessageW consumes the quit flag, so the next call will
            // block normally for real messages.
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) {
            // GetMessageW already removed this message from the queue.
            self.discardOpenUrlRequest(msg);
            break;
        }

        // Dispatch a global hotkey to its bound action.
        if (msg.message == w32.WM_HOTKEY) {
            const id: i32 = @intCast(msg.wParam);
            for (self.global_hotkeys.items) |hk| {
                if (hk.id != id) continue;
                // apprt.App is this win32 App, so `self` is the rt_app.
                self.core_app.performAllAction(self, hk.action) catch |err| {
                    log.warn("global hotkey action failed err={}", .{err});
                };
                break;
            }
            continue;
        }

        // Overview controls belong to TabOverview, not Surface. Route them
        // before the legacy popup code interprets the parent's userdata.
        // Include hidden controls so queued keys cannot reach that cast.
        if (msg.hwnd) |hwnd| {
            for (self.windows.items) |win| {
                if (!win.tab_overview.ownsInput(hwnd)) continue;
                if (msg.message == w32.WM_KEYDOWN) {
                    if (!win.tab_overview.active) continue :loop;
                    const vk: u16 = @truncate(msg.wParam);
                    if (win.tab_overview.handleKey(hwnd, vk)) continue :loop;
                    const ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
                    const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
                    if (ctrl and (shift or !isEditShortcutVk(vk))) {
                        win.tab_overview.hide(true);
                        if (win.getActiveSurface()) |surface|
                            surface.handleKeyEvent(msg.wParam, msg.lParam, .press);
                        continue :loop;
                    }
                }
                if (w32.IsDialogMessageW(win.tab_overview.hwnd.?, &msg) == 0) {
                    _ = w32.TranslateMessage(&msg);
                    _ = w32.DispatchMessageW(&msg);
                }
                continue :loop;
            }
        }

        // Intercept keystrokes destined for popup edit controls so
        // Enter/Escape/Arrow keys can be handled by our code.
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);

            // Check if this edit is a tab rename edit
            if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
                for (self.windows.items) |win| {
                    if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                        if (vk == w32.VK_RETURN) {
                            tab_rename.finishTabRename(win);
                        } else {
                            tab_rename.cancelTabRename(win);
                        }
                        continue :loop;
                    }
                }
            }

            // Find the parent surface of this edit control
            if (self.popupSurface(msg.hwnd.?)) |surface| {
                if (surface.search_active and surface.search_edit == msg.hwnd) {
                    if (find_bar.handleSearchKey(surface, vk)) continue;
                }
                if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                    if (command_palette.handlePaletteKey(surface, vk)) continue;
                }
            }

            // Bubble global keybindings from popup edit controls (tab
            // rename, command palette, search) up to the surface so that
            // e.g. `Ctrl+Shift+P` while renaming actually toggles the
            // palette instead of being eaten by the Edit. Excludes
            // Ctrl-only A/C/V/X/Y/Z so standard text-edit shortcuts keep
            // working inside the popup.
            const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
            const shift_held = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const route_key = ctrl_held and (shift_held or !isEditShortcutVk(vk));
            if (route_key) {
                const target_surface: ?*Surface = blk: {
                    // Tab rename edit lives on the Window, not a surface.
                    // Commit (not cancel) — matches standard Win32 inline
                    // rename convention (Explorer, Edge): any action that
                    // takes focus away saves the typed title.
                    for (self.windows.items) |win| {
                        if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                            tab_rename.finishTabRename(win);
                            break :blk win.getActiveSurface();
                        }
                    }
                    // Palette/search edits are children of a surface HWND.
                    const surface = self.popupSurface(msg.hwnd.?) orelse break :blk null;
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        command_palette.setCommandPaletteActive(surface, false);
                        break :blk surface;
                    }
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        find_bar.setSearchActive(surface, false, &[_:0]u8{});
                        break :blk surface;
                    }
                    break :blk null;
                };
                if (target_surface) |s| {
                    s.handleKeyEvent(msg.wParam, msg.lParam, .press);
                    continue :loop;
                }
            }
        }

        if (msg.message == w32.WM_KEYDOWN) {
            if (self.profileShortcut(msg)) continue :loop;
        }

        // Skip TranslateMessage for keyboard events on terminal surface
        // windows: handleKeyEvent (and sendWin32InputEvent in Win32 input
        // mode) calls ToUnicode directly, and TranslateMessage's internal
        // ToUnicodeEx mutates the same per-queue dead-key state — racing
        // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
        // controls (search, palette, tab rename) still need it.
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                // Keys claimed by the IME arrive as VK_PROCESSKEY and MUST
                // go through TranslateMessage: that is what forwards them to
                // the IME (ImmTranslateMessage) to generate the
                // WM_IME_STARTCOMPOSITION/WM_IME_COMPOSITION messages and
                // drive the candidate window. Skipping it made CJK input
                // dead. This does not disturb the ToUnicode dead-key state:
                // handleKeyEvent never calls ToUnicode for VK_PROCESSKEY.
                if (msg.wParam == w32.VK_PROCESSKEY) break :blk false;
                // VK_PACKET carries text from SendInput (on-screen keyboard,
                // dictation, AutoHotkey, password managers). Only
                // TranslateMessage turns it into the WM_CHAR holding the
                // character, and it never touches dead-key state.
                if (msg.wParam == w32.VK_PACKET) break :blk false;
                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk atom != 0 and atom == self.terminal_class_atom;
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.stopQuitTimer();
    updater.installOnQuit();

    // Unregister all global hotkeys.
    for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
    self.global_hotkeys.deinit(self.core_app.alloc);

    // Release the taskbar COM object if we created one.
    if (self.taskbar) |tb| {
        tb.Release();
        self.taskbar = null;
    }

    // Destroy quick terminal if active.
    if (self.quick_terminal) |qt| {
        qt.deinit();
        self.quick_terminal = null;
    }

    if (self.msg_hwnd) |hwnd| {
        // Clear GWLP_USERDATA before destroying so msgWndProc sees
        // userdata=0 and falls through to DefWindowProc for any
        // messages during destruction (e.g. WM_DESTROY).
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        self.discardPendingOpenUrls();
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    // Deinit and free all Window containers.
    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.overview_class_atom != 0) {
        _ = w32.UnregisterClassW(TabOverview.class_name, self.hinstance);
        self.overview_class_atom = 0;
    }
    if (self.settings_class_atom != 0) {
        _ = w32.UnregisterClassW(SettingsPanel.class_name, self.hinstance);
        self.settings_class_atom = 0;
    }
    canvas.unloadEmbeddedFonts(self.ui_fonts);
    self.ui_fonts = .{ null, null };
    self.profile_icons.deinit();
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }

    self.config.deinit();
}

/// Wake up the message loop from any thread by posting a message
/// to the message-only window.
pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}

/// IPC from external processes. Not yet implemented for Win32.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

/// The core asks the app to act; actions.zig carries each action out.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return actions.performAction(self, target, action, value);
}

/// Open the config file itself, in an editor.
pub fn openConfigFile(self: *App, how: apprt.action.OpenConfig) bool {
    const config_path = configpkg.edit.openPath(self.core_app.alloc) catch |err| {
        log.err("failed to get config path: {}", .{err});
        return false;
    };
    defer self.core_app.alloc.free(config_path);
    return switch (how) {
        .os_open => self.openConfigWithOs(config_path),
        .new_window => (self.openConfigInNewWindow(config_path) catch false) or
            self.openConfigWithOs(config_path),
    };
}

/// Save the open tabs for the sidebar layout to reopen at startup.
/// Follow the auto-update setting: `auto-update = off` stops the
/// automatic checks (check and download both download on Windows).
pub fn configureUpdater(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    updater.configure(hwnd, WM_APP_UPDATE, self.config.@"auto-update" != .off);
}

/// Follow `default-terminal`: take consoles Windows hands over while it
/// is on, or while Windows started Sharp for one. Only a change of the
/// setting (`changed`) claims Windows' choice or gives it back, so a
/// terminal picked in Windows' own settings since then stays picked.
pub fn configureDefaultTerminal(self: *App, changed: bool) void {
    const on = self.config.@"default-terminal";
    if (changed) {
        if (on) {
            default_terminal.claim() catch |err| log.warn("could not make Sharp the default terminal: {}", .{err});
        } else default_terminal.release();
    } else if (on) default_terminal.refresh();

    const hwnd = self.msg_hwnd orelse return;
    if (on or terminal_handoff.launchedByWindows()) {
        terminal_handoff.start(hwnd, WM_APP_HANDOFF);
    } else terminal_handoff.stop();
}

/// Open a console Windows handed over in a tab of the newest window, or
/// a new window when there is none. Its program ends if it can't open.
fn openHandedOver(self: *App, handed: *const terminal_handoff.Handed) void {
    var name: [32]u8 = undefined;
    const command_text = internal_os.console_handoff.command(handed.id, &name) orelse
        return internal_os.console_handoff.discard(handed.id);
    const argv = [_][:0]const u8{command_text};
    const command: configpkg.Command = .{ .direct = &argv };
    const window = self.handoffWindow() catch |err| {
        log.warn("no window for a handed-over console: {}", .{err});
        return internal_os.console_handoff.discard(handed.id);
    };
    _ = window.addTabWithOptions(.{
        .context = .tab,
        .command = &command,
        .icon = self.profile_icons.get(handed.program(), window.tabIconSize()),
        .profile_name = handed.name(),
    }) catch |err| {
        log.warn("could not open a handed-over console: {}", .{err});
        return internal_os.console_handoff.discard(handed.id);
    };
    if (window.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
}

fn handoffWindow(self: *App) !*Window {
    var i = self.windows.items.len;
    while (i > 0) {
        i -= 1;
        const window = self.windows.items[i];
        if (!window.is_quick_terminal and !window.closing) return window;
    }
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, .{});
    errdefer window.deinit();
    try self.windows.append(alloc, window);
    return window;
}

/// Restart into a downloaded update, after asking: running programs end.
pub fn restartToUpdate(self: *App, owner: ?w32.HWND) void {
    var buf: [600]u8 = undefined;
    var wide: [600]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, updater.restartPrompt(&buf));
    var title: [64]u16 = undefined;
    _ = wide_string.fromUtf8(&title, updater.data.restart_title);
    if (w32.MessageBoxW(owner, @ptrCast(&wide), @ptrCast(&title), w32.MB_YESNO | w32.MB_ICONQUESTION) != w32.IDYES) return;
    self.saveSession();
    if (!updater.install(true)) return;
    self.quit_requested = true;
    w32.PostQuitMessage(0);
}

pub fn saveSession(self: *App) void {
    if (self.config.@"window-tab-bar-position" != .sidebar or self.restoring_session) return;
    var windows: [16]session.Window = undefined;
    var tabs: [16][64]session.Tab = undefined;
    var count: usize = 0;
    var any_closing = false;
    for (self.windows.items) |window| {
        if (window.closing) {
            any_closing = true;
            continue;
        }
        if (window.tab_count == 0 or count == windows.len) continue;
        windows[count] = workspace.sessionWindow(window, &tabs[count]);
        count += 1;
    }
    // Closing the last window quits: keep what it had open for next time.
    if (count == 0 and any_closing) return;
    const first = if (self.windows.items.len > 0) self.windows.items[0] else return;
    var collapsed: [Window.max_collapsed][]const u8 = undefined;
    var recent: [servers.Recent.capacity][]const u8 = undefined;
    session.save(self.core_app.alloc, .{
        .windows = windows[0..count],
        .width = first.sidebar_width,
        .collapsed = workspace.collapsedGroups(first, &collapsed),
        .servers = self.recent_servers.names(&recent),
    }) catch |err| log.warn("failed to save the session: {}", .{err});
}

/// Reopen the saved tabs, using `first` for the first saved window.
/// Returns false when there is nothing to restore.
fn restoreSession(self: *App, first: *Window) !bool {
    if (self.config.@"window-tab-bar-position" != .sidebar) return false;
    const alloc = self.core_app.alloc;
    var loaded = (try session.load(alloc, first.sidebar_width)) orelse return false;
    defer loaded.deinit();
    const saved = loaded.session;
    // Oldest first, so the most recent ends up on top.
    var n = saved.servers.len;
    while (n > 0) {
        n -= 1;
        _ = self.recent_servers.add(saved.servers[n]);
    }
    if (saved.windows.len == 0 or saved.windows[0].tabs.len == 0) return false;

    self.restoring_session = true;
    defer self.restoring_session = false;
    // No more windows than saveSession can write back.
    for (saved.windows[0..@min(saved.windows.len, 16)], 0..) |saved_window, i| {
        if (saved_window.tabs.len == 0) continue;
        const window = if (i == 0) first else window: {
            const w = try alloc.create(Window);
            w.init(self, .{}) catch |err| {
                alloc.destroy(w);
                return err;
            };
            self.windows.append(alloc, w) catch |err| {
                w.deinit();
                alloc.destroy(w);
                return err;
            };
            break :window w;
        };
        workspace.restoreSidebar(window, saved.width, saved.collapsed);
        for (saved_window.tabs) |tab| workspace.openSavedTab(window, tab);
        if (window.tab_count == 0) {
            _ = try window.addTab();
        } else {
            window.selectTabIndex(@min(saved_window.active, window.tab_count - 1));
        }
    }
    return true;
}

/// Open a new window whose first tab uses `options`.
pub fn openWindowWithTab(self: *App, options: Window.AddTabOptions) !void {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    window.init(self, .{}) catch |err| {
        alloc.destroy(window);
        return err;
    };
    self.windows.append(alloc, window) catch |err| {
        window.deinit();
        alloc.destroy(window);
        return err;
    };
    _ = window.addTabWithOptions(options) catch |err| {
        window.close();
        return err;
    };
}

/// Open the configuration with the Windows file association, or Notepad
/// when nothing is registered for `.ghostty` files, which is the usual
/// case on a fresh machine.
fn openConfigWithOs(self: *App, path: [:0]const u8) bool {
    const alloc = self.core_app.alloc;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| {
        log.warn("unable to encode config path: {}", .{err});
        return false;
    };
    defer alloc.free(path_w);

    const open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    if (w32.ShellExecuteW(null, open, path_w, null, null, w32.SW_SHOW) > 32) return true;

    // Windows paths cannot contain a double quote, so quoting is enough.
    const quoted = std.fmt.allocPrint(alloc, "\"{s}\"", .{path}) catch return false;
    defer alloc.free(quoted);
    const quoted_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, quoted) catch return false;
    defer alloc.free(quoted_w);
    const notepad = std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe");
    return w32.ShellExecuteW(null, open, notepad, quoted_w, null, w32.SW_SHOW) > 32;
}

/// Open the configuration in a new Ghostty window using VISUAL or EDITOR.
/// Returns false when no terminal editor is configured so callers can fall
/// back to the Windows file association.
fn openConfigInNewWindow(self: *App, path: [:0]const u8) !bool {
    const alloc = self.core_app.alloc;
    const editor = global.environ().getAlloc(alloc, "VISUAL") catch
        global.environ().getAlloc(alloc, "EDITOR") catch return false;
    defer alloc.free(editor);
    if (std.mem.trim(u8, editor, " \t\r\n").len == 0) return false;

    // Windows paths cannot contain a double quote, so quoting the path is
    // sufficient while leaving editor arguments supplied by the user intact.
    const command_text = try alloc.printSentinel(
        "{s} \"{s}\"",
        .{ editor, path },
        0,
    );
    defer alloc.free(command_text);
    const command: configpkg.Command = .{ .shell = command_text };

    const title = try alloc.printSentinel(
        "Editing configuration file {s}",
        .{path},
        0,
    );
    defer alloc.free(title);

    try self.openWindowWithTab(.{
        .context = .window,
        .command = &command,
        .title = title,
    });
    return true;
}

/// Present a native Save As dialog and write the borrowed terminal-I/O log
/// before returning from the action callback.
fn exportTerminalIo(self: *App, target: apprt.Target, contents: []const u8) bool {
    const owner = switch (target) {
        .app => return false,
        .surface => |core_surface| core_surface.rt_surface.parent_window.hwnd,
    };

    var file_buf: [32768]u16 = std.mem.zeroes([32768]u16);
    const default_name = std.unicode.utf8ToUtf16LeStringLiteral("sharp-terminal-io.txt");
    @memcpy(file_buf[0..default_name.len], default_name);

    // The common-dialog filter is a sequence of NUL-terminated label/pattern
    // pairs followed by an additional NUL.
    const filter = std.unicode.utf8ToUtf16LeStringLiteral(
        "Text files (*.txt)\x00*.txt\x00All files (*.*)\x00*.*\x00",
    );
    var dialog: w32.OPENFILENAMEW = std.mem.zeroes(w32.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(w32.OPENFILENAMEW);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = filter;
    dialog.nFilterIndex = 1;
    dialog.lpstrFile = &file_buf;
    dialog.nMaxFile = file_buf.len;
    dialog.lpstrTitle = std.unicode.utf8ToUtf16LeStringLiteral("Export Terminal IO Events");
    dialog.lpstrDefExt = std.unicode.utf8ToUtf16LeStringLiteral("txt");
    dialog.Flags = w32.OFN_EXPLORER |
        w32.OFN_NOCHANGEDIR |
        w32.OFN_PATHMUSTEXIST |
        w32.OFN_OVERWRITEPROMPT;

    // Cancellation is a handled action, just with no file written.
    if (w32.GetSaveFileNameW(&dialog) == 0) return true;

    const path_len = std.mem.indexOfScalar(u16, &file_buf, 0) orelse file_buf.len;
    const alloc = self.core_app.alloc;
    const path = std.unicode.utf16LeToUtf8Alloc(alloc, file_buf[0..path_len]) catch |err| {
        log.warn("unable to decode terminal IO export path: {}", .{err});
        return false;
    };
    defer alloc.free(path);

    var file = std.Io.Dir.createFileAbsolute(global.io(), path, .{ .truncate = true }) catch |err| {
        log.warn("unable to create terminal IO export file: {}", .{err});
        return false;
    };
    defer file.close(global.io());
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(global.io(), &write_buf);
    writer.interface.writeAll(contents) catch |err| {
        log.warn("unable to write terminal IO export file: {}", .{err});
        return false;
    };
    writer.interface.flush() catch |err| {
        log.warn("unable to flush terminal IO export file: {}", .{err});
        return false;
    };
    return true;
}

/// Ctrl-modified VKs that should remain with the focused Edit control
/// rather than bubbling to the surface as a keybinding. Select-all,
/// copy, paste, cut, redo, undo.
fn isEditShortcutVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}

/// Only surface-class parents store Surface userdata. A terminal child has
/// a Window parent; interpreting that pointer as Surface is invalid even
/// when we only intended to check whether a popup edit is active.
/// Ctrl+Shift+1..9 on a terminal opens that profile in a new tab, as in
/// Windows Terminal. Returns whether the key was used.
fn profileShortcut(self: *App, msg: w32.MSG) bool {
    const vk: u16 = @truncate(msg.wParam);
    if (vk < '1' or vk > '9') return false;
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) >= 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) >= 0 or
        w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) return false;
    // A keybind in the config file for this chord wins, so the shortcut
    // can be moved or switched off (`keybind = ctrl+shift+1=ignore`).
    const digits = [_]input.Key{ .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 };
    const mods: input.Mods = .{ .ctrl = true, .shift = true };
    const set = &self.config.keybind.set;
    if (set.get(.{ .mods = mods, .key = .{ .physical = digits[vk - '1'] } }) != null or
        set.get(.{ .mods = mods, .key = .{ .unicode = vk } }) != null) return false;
    const hwnd = msg.hwnd orelse return false;
    if (@as(u16, @truncate(w32.GetClassLongW(hwnd, w32.GCW_ATOM))) != self.terminal_class_atom) return false;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return false;
    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
    surface.parent_window.openProfile(vk - '1', false);
    return true;
}

fn popupSurface(self: *const App, child: w32.HWND) ?*Surface {
    const parent = w32.GetParent(child) orelse return null;
    if (self.terminal_class_atom == 0 or
        @as(u16, @truncate(w32.GetClassLongW(parent, w32.GCW_ATOM))) != self.terminal_class_atom)
        return null;
    const userdata = w32.GetWindowLongPtrW(parent, w32.GWLP_USERDATA);
    if (userdata == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(userdata)));
}

/// Lazily create (and cache) the shell ITaskbarList3 used for taskbar-button
/// progress. Returns null if COM or the taskbar object is unavailable.
pub fn taskbarList(self: *App) ?*w32.ITaskbarList3 {
    if (self.taskbar) |tb| return tb;

    // COM must be initialized on this (the UI) thread before CoCreateInstance.
    // S_FALSE (already initialized) is fine; we only need it done once.
    if (!self.com_initialized) {
        _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
        self.com_initialized = true;
    }

    var ptr: ?*anyopaque = null;
    const hr = w32.CoCreateInstance(
        &w32.CLSID_TaskbarList,
        null,
        w32.CLSCTX_INPROC_SERVER,
        &w32.IID_ITaskbarList3,
        &ptr,
    );
    if (hr < 0 or ptr == null) return null;

    const tb: *w32.ITaskbarList3 = @ptrCast(@alignCast(ptr.?));
    _ = tb.HrInit();
    self.taskbar = tb;
    return tb;
}

// -----------------------------------------------------------------------
// Notifications
// -----------------------------------------------------------------------

/// Tray-icon notification callback (uCallbackMessage). The wparam is
/// the tray icon's uID; lparam carries NIN_* events.
const WM_APP_TRAY: u32 = w32.WM_APP + 3;

/// Tray icon and cleanup timer of desktop notifications.
const NOTIF_DESKTOP_UID: u32 = 1;
const NOTIF_DESKTOP_TIMER_ID: usize = 2;

/// Start the quit timer. Called when the last surface closes.
pub fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();

    // Check if we should quit at all.
    if (!self.config.@"quit-after-last-window-closed") return;

    // If a delay is configured, start a Win32 timer.
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        // No delay — quit immediately.
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}

/// Cancel the quit timer. Called when a new surface opens.
pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            // Reset quit_requested. The WM_QUIT posted by startQuitTimer's
            // no-delay path can't be removed from the queue (it's a flag,
            // not a real message). Instead, the message loop checks
            // quit_requested when GetMessageW returns 0 — if false, it
            // ignores the spurious WM_QUIT and continues. This handles
            // the normal startup sequence: main_ghostty calls
            // startQuitTimer() before any surfaces exist, then run()
            // creates the first surface which triggers stopQuitTimer().
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
pub fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    // Remember the originating surface so a balloon click can focus it.
    self.notif_desktop_surface_id = switch (target) {
        .app => 0,
        .surface => |core_surface| core_surface.id,
    };
    self.showDesktopNotificationText(value.title, value.body);
}

/// Show a desktop toast with the given title/body via the tray icon. The
/// balloon click is delivered as WM_APP_TRAY (NIF_MESSAGE) and focuses the
/// surface stored in notif_desktop_surface_id, mirroring macOS/GTK where
/// clicking a notification presents the originating surface.
pub fn showDesktopNotificationText(self: *App, title: []const u8, body: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    // Copy title (UTF-8 → UTF-16LE)
    _ = wide_string.fromUtf8(&nid.szInfoTitle, title);

    // Copy body (UTF-8 → UTF-16LE)
    _ = wide_string.fromUtf8(&nid.szInfo, body);

    // Tooltip
    const tip = std.unicode.utf8ToUtf16LeStringLiteral(brand.name);
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    // Add the icon, show notification, then remove the icon.
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Schedule icon removal.
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_ID, 6000, null);
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// Open a URL in the default handler. internal_os.open() uses
/// std.process.Child which can hit unreachable on Windows, so we use
/// ShellExecuteW directly.
fn openUrlNow(value: apprt.action.OpenUrl) void {
    const decision = UntrustedUrl.decide(value);
    if (decision == .deny) {
        log.warn("blocked unsafe terminal URL", .{});
        return;
    }
    const url = value.url;
    var wbuf: [2048]u16 = undefined;
    // A truncated URL would open a different target, so refuse instead. A
    // UTF-8 string never needs more UTF-16 units than it has bytes.
    if (url.len >= wbuf.len) return;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, url) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;
    if (decision == .confirm) {
        var prompt_buf: [8192]u8 = undefined;
        const prompt = std.mem.print(&prompt_buf, "Open this terminal-supplied link in its registered application?\n" ++
            "This may execute commands. Continue only if you trust the target.\n\n{s}", .{url}) catch return;
        var wide_prompt: [8192]u16 = undefined;
        const prompt_len = std.unicode.utf8ToUtf16Le(&wide_prompt, prompt) catch return;
        if (prompt_len >= wide_prompt.len) return;
        wide_prompt[prompt_len] = 0;
        if (w32.MessageBoxW(null, @ptrCast(&wide_prompt), std.unicode.utf8ToUtf16LeStringLiteral("Open external link?"), w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2) != w32.IDOK) return;
    }
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wbuf),
        null,
        null,
        w32.SW_SHOW,
    );
}

/// Posted payloads are not freed by DestroyWindow if we quit before
/// dispatching them. Discard them without opening URLs during shutdown.
fn discardPendingOpenUrls(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    var msg: w32.MSG = undefined;
    while (w32.PeekMessageW(&msg, hwnd, WM_APP_OPEN_URL, WM_APP_OPEN_URL, w32.PM_REMOVE) != 0) {
        self.discardOpenUrlRequest(msg);
    }
}

fn discardOpenUrlRequest(self: *App, msg: w32.MSG) void {
    if (msg.message == WM_APP_OPEN_URL and msg.wParam != 0) {
        const request: *OpenUrlRequest = @ptrFromInt(msg.wParam);
        request.deinit(self.core_app.alloc);
    }
}

/// Window procedure for the message-only HWND (GhosttyMsg class).
/// GWLP_USERDATA stores an *App pointer.
fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (msg == WM_APP_WAKEUP) {
        app.tick();
        return 0;
    }

    if (msg == WM_APP_AI_USAGE) {
        for (app.windows.items) |window| window.invalidateTabBar();
        return 0;
    }

    if (msg == WM_APP_HANDOFF) {
        while (terminal_handoff.next()) |handed| app.openHandedOver(&handed);
        return 0;
    }

    if (msg == WM_APP_UPDATE) {
        for (app.windows.items) |window| window.invalidateTabBar();
        var buf: [1024]u8 = undefined;
        if (updater.takeReport(&buf)) |text| {
            var wide: [512]u16 = undefined;
            _ = wide_string.fromUtf8(&wide, text);
            var title: [64]u16 = undefined;
            _ = wide_string.fromUtf8(&title, updater.data.restart_title);
            const owner = if (app.windows.items.len > 0) app.windows.items[0].hwnd else null;
            _ = w32.MessageBoxW(owner, @ptrCast(&wide), @ptrCast(&title), w32.MB_OK | w32.MB_ICONINFORMATION);
        }
        return 0;
    }

    if (msg == browser_remote.message) {
        browser_remote.serve(app, @ptrFromInt(wparam));
        return 0;
    }

    if (msg == WM_APP_OPEN_URL) {
        // Preserve the trust hint alongside the owned URL until dispatch.
        if (wparam != 0) {
            const request: *OpenUrlRequest = @ptrFromInt(wparam);
            defer request.deinit(app.core_app.alloc);
            openUrlNow(.{ .kind = request.kind, .url = request.url });
        }
        return 0;
    }

    if (msg == WM_APP_TRAY) {
        // wparam = uID, lparam = NIN_* event. Clicking a desktop
        // notification's balloon focuses the terminal that sent it.
        const event: u32 = @intCast(lparam & 0xFFFF);
        if (wparam == NOTIF_DESKTOP_UID and event == w32.NIN_BALLOONUSERCLICK) {
            // Focus the surface that produced the notification (click-to-
            // focus, matching macOS/GTK).
            if (app.notif_desktop_surface_id != 0) {
                if (app.core_app.findSurfaceByID(app.notif_desktop_surface_id)) |surface| {
                    _ = actions.performAction(
                        app,
                        .{ .surface = surface },
                        .present_terminal,
                        {},
                    ) catch |err| {
                        log.warn("present_terminal from notification failed err={}", .{err});
                    };
                }
            }
            return 0;
        }
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    // Timer ID 3: quick terminal animation tick.
    if (msg == w32.WM_TIMER and wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| qt.onAnimationTick();
        return 0;
    }

    // The notification icon's cleanup timer.
    if (msg == w32.WM_TIMER and wparam == NOTIF_DESKTOP_TIMER_ID) {
        const uid = NOTIF_DESKTOP_UID;
        _ = w32.KillTimer(hwnd, wparam);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = uid;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }

    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "tab overview popup routing rejects container userdata" {
    const instance = w32.GetModuleHandleW(null) orelse return error.Win32Error;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyPopupRoutingTest");
    const atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    });
    if (atom == 0) return error.Win32Error;
    defer _ = w32.UnregisterClassW(name, instance);
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const container = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), empty, 0, 0, 0, 1, 1, null, null, instance, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(container);
    const terminal = w32.CreateWindowExW(0, name, empty, w32.WS_CHILD, 0, 0, 1, 1, container, null, instance, null) orelse return error.Win32Error;
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = instance, .terminal_class_atom = atom };
    // A non-Surface sentinel must never be dereferenced during routing.
    _ = w32.SetWindowLongPtrW(container, w32.GWLP_USERDATA, 1);
    try std.testing.expectEqual(@as(?*Surface, null), app.popupSurface(terminal));
    const edit = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), empty, w32.WS_CHILD, 0, 0, 1, 1, terminal, null, instance, null) orelse return error.Win32Error;
    var surface: Surface = .{ .app = &app };
    _ = w32.SetWindowLongPtrW(terminal, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&surface)));
    try std.testing.expectEqual(@as(?*Surface, &surface), app.popupSurface(edit));
}

test "detached tab keeps hidden popups and popup destruction preserves terminal" {
    const testing = std.testing;
    const Native = struct {
        extern "user32" fn IsWindow(hwnd: w32.HWND) callconv(.winapi) i32;

        fn create(class: [*:0]const u16, style: u32, parent: ?w32.HWND, instance: w32.HINSTANCE) !w32.HWND {
            return w32.CreateWindowExW(0, class, std.unicode.utf8ToUtf16LeStringLiteral(""), style, 0, 0, 1, 1, parent, null, instance, null) orelse error.Win32Error;
        }
    };
    const instance = w32.GetModuleHandleW(null) orelse return error.Win32Error;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDetachedPopupTest");
    if (w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &pane_messages.surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    }) == 0) return error.Win32Error;
    defer _ = w32.UnregisterClassW(class, instance);

    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = instance };
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.* = .{ .app = &app };
    const static = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const source = try Native.create(static, 0, null, instance);
    var source_alive = true;
    defer if (source_alive) {
        _ = w32.DestroyWindow(source);
    };
    const destination = try Native.create(static, 0, null, instance);
    defer _ = w32.DestroyWindow(destination);
    const child = try Native.create(class, w32.WS_CHILD, source, instance);
    const search = try Native.create(class, w32.WS_POPUP, source, instance);
    const palette = try Native.create(class, w32.WS_POPUP, source, instance);
    const preview = try Native.create(static, w32.WS_POPUP, source, instance);
    surface.hwnd = child;
    surface.search_hwnd = search;
    surface.search_edit = try Native.create(std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), w32.WS_CHILD, search, instance);
    surface.search_count_label = try Native.create(static, w32.WS_CHILD, search, instance);
    surface.palette_hwnd = palette;
    surface.palette_edit = try Native.create(std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), w32.WS_CHILD, palette, instance);
    surface.link_preview_hwnd = preview;
    for ([_]w32.HWND{ child, search, palette }) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(surface)));
    }
    defer for ([_]w32.HWND{ child, search, palette }) |hwnd| {
        if (Native.IsWindow(hwnd) != 0) _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    };

    // Popups persist after dismissal. Exercise the production transfer on
    // hidden real HWNDs, without a renderer, focus changes, or global input.
    try surface.reparentNativeWindows(destination);
    surface.core_surface_ready = true;
    for ([_]w32.HWND{ search, palette, preview }) |hwnd| {
        try testing.expectEqual(@as(i32, 0), w32.IsWindowVisible_(hwnd));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(destination))), w32.GetWindowLongPtrW(hwnd, w32.GWLP_HWNDPARENT));
    }
    try testing.expect(w32.DestroyWindow(source) != 0);
    source_alive = false;
    for ([_]w32.HWND{ child, search, palette, preview }) |hwnd| {
        try testing.expect(Native.IsWindow(hwnd) != 0);
    }
    try testing.expectEqual(@as(?w32.HWND, child), surface.hwnd);
    try testing.expect(surface.core_surface_ready);

    // Popup WM_DESTROY must clear only its own cached handles/state. The
    // terminal remains usable, and a later open can create a new popup.
    surface.search_active = true;
    surface.search_total = 3;
    surface.search_selected = 1;
    try testing.expect(w32.DestroyWindow(search) != 0);
    try testing.expect(surface.search_hwnd == null);
    try testing.expect(surface.search_edit == null);
    try testing.expect(surface.search_count_label == null);
    try testing.expect(!surface.search_active);
    try testing.expect(surface.search_total == null);
    try testing.expect(surface.search_selected == null);
    try testing.expectEqual(@as(?w32.HWND, palette), surface.palette_hwnd);
    try testing.expectEqual(@as(?w32.HWND, child), surface.hwnd);
    try testing.expect(surface.core_surface_ready);

    surface.palette_active = true;
    try testing.expect(w32.DestroyWindow(palette) != 0);
    try testing.expect(surface.palette_hwnd == null);
    try testing.expect(surface.palette_edit == null);
    try testing.expect(!surface.palette_active);
    try testing.expectEqual(@as(?w32.HWND, child), surface.hwnd);
    try testing.expect(surface.core_surface_ready);

    try testing.expect(w32.DestroyWindow(child) != 0);
    try testing.expect(surface.hwnd == null);
    try testing.expect(!surface.core_surface_ready);
}

test "export terminal IO requires a surface target" {
    var app: App = undefined;
    try std.testing.expect(!app.exportTerminalIo(.app, "test contents"));
}

test "open URL is deferred and owns its input until dispatch" {
    const testing = std.testing;
    // A system message-only window lets us inspect the posted request
    // without launching a browser or initializing a renderer.
    const hwnd = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0,
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.msg_hwnd = hwnd;
    defer app.discardPendingOpenUrls();

    // Invalid UTF-8 also keeps a regression to synchronous ShellExecuteW
    // from launching a browser in the test runner.
    const original = "https://example.com/\xff";
    var url = original.*;
    try testing.expect(try actions.performAction(app, .app, .open_url, .{
        .kind = .osc8,
        .url = &url,
    }));
    @memset(&url, 'x');

    var msg: w32.MSG = undefined;
    try testing.expect(w32.PeekMessageW(&msg, hwnd, WM_APP_OPEN_URL, WM_APP_OPEN_URL, w32.PM_REMOVE) != 0);
    const request: *OpenUrlRequest = @ptrFromInt(msg.wParam);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&app)));
    defer _ = msgWndProc(hwnd, msg.message, msg.wParam, msg.lParam);
    try testing.expectEqualStrings(original, request.url);
    try testing.expectEqual(apprt.action.OpenUrl.Kind.osc8, request.kind);
}

test "open URL frees undelivered requests" {
    const testing = std.testing;
    const hwnd = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0,
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.Win32Error;
    var window_alive = true;
    defer if (window_alive) {
        _ = w32.DestroyWindow(hwnd);
    };

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.msg_hwnd = hwnd;
    defer app.discardPendingOpenUrls();

    try testing.expect(try actions.performAction(app, .app, .open_url, .{
        .kind = .osc8,
        .url = "",
    }));
    var msg: w32.MSG = undefined;
    try testing.expectEqual(@as(i32, 0), w32.PeekMessageW(&msg, hwnd, WM_APP_OPEN_URL, WM_APP_OPEN_URL, w32.PM_REMOVE));

    // The testing allocator detects leaks both when shutdown discards a
    // successfully posted request and when PostMessageW fails.
    for (0..2) |_| {
        try testing.expect(try actions.performAction(app, .app, .open_url, .{
            .kind = .osc8,
            .url = "https://example.com/\xff",
        }));
    }
    // One request has already been dequeued when run() notices a quit;
    // the other is still pending when terminate() destroys the HWND.
    try testing.expect(w32.PeekMessageW(&msg, hwnd, WM_APP_OPEN_URL, WM_APP_OPEN_URL, w32.PM_REMOVE) != 0);
    app.discardOpenUrlRequest(msg);
    app.discardPendingOpenUrls();
    try testing.expectEqual(@as(i32, 0), w32.PeekMessageW(&msg, hwnd, WM_APP_OPEN_URL, WM_APP_OPEN_URL, w32.PM_REMOVE));

    try testing.expect(w32.DestroyWindow(hwnd) != 0);
    window_alive = false;
    try testing.expect(try actions.performAction(app, .app, .open_url, .{
        .kind = .osc8,
        .url = "https://example.com/\xff",
    }));
    app.msg_hwnd = null;
    try testing.expect(try actions.performAction(app, .app, .open_url, .{
        .kind = .osc8,
        .url = "https://example.com/\xff",
    }));
}
