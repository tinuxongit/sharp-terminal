//! How Sharp carries out each action the Ghostty core asks of the Windows
//! app (new tabs and windows, titles, splits, clipboard, notifications,
//! fullscreen and the rest): the core's performAction, one case per action.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const session = @import("session.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const brand = @import("brand.zig");
const wide_string = @import("wide_string.zig");
const find_bar = @import("find_bar.zig");
const command_palette = @import("command_palette.zig");
const clipboard = @import("clipboard.zig");
const workspace = @import("workspace.zig");
const tab_rename = @import("tab_rename.zig");
const splits = @import("splits.zig");
const log = std.log.scoped(.win32);
const App = @import("App.zig");
const global_hotkey = @import("global_hotkey.zig");

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            // Inherit opacity-toggle state from the parent window: if the
            // user toggled it to opaque via toggle_background_opacity, the
            // new window should start opaque too. Mirrors macOS behavior
            // from upstream e5c31e8b3 (#11583).
            const force_opaque: bool = switch (target) {
                .app => false,
                .surface => |cs| blk: {
                    if (self.config.@"background-opacity" >= 1.0) break :blk false;
                    const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
                    const ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                    break :blk (ex & w32.WS_EX_LAYERED) == 0;
                },
            };

            const alloc = self.core_app.alloc;
            const window = alloc.create(Window) catch |err| {
                log.err("failed to allocate new window err={}", .{err});
                return true;
            };
            window.init(self, .{ .force_opaque = force_opaque }) catch |err| {
                log.err("failed to init new window err={}", .{err});
                alloc.destroy(window);
                return true;
            };
            self.windows.append(alloc, window) catch |err| {
                log.err("failed to track new window err={}", .{err});
                window.deinit();
                alloc.destroy(window);
                return true;
            };
            _ = window.addTab() catch |err| {
                log.err("failed to add tab to new window err={}", .{err});
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .pwd => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // Shells like cmd report at every prompt; only a real
                    // change repaints and rewrites the session.
                    if (core_surface.rt_surface.setFolder(value.pwd)) {
                        core_surface.rt_surface.parent_window.invalidateTabBar();
                        self.saveSession();
                    }
                },
            }
            return true;
        },

        .ring_bell => {
            // A bell from a tab out of sight marks it in the tab sidebar.
            switch (target) {
                .app => {},
                .surface => |core_surface| workspace.noteBell(core_surface.rt_surface.parent_window, core_surface.rt_surface),
            }
            // Audio bell.
            _ = w32.MessageBeep(0xFFFFFFFF);
            // Visual bell: flash the taskbar button if the window owning
            // this surface isn't currently the foreground window. Without
            // this, BEL on a backgrounded terminal is invisible.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                        if (w32.GetForegroundWindow() != win_hwnd) {
                            var fwi: w32.FLASHWINFO = .{
                                .cbSize = @sizeOf(w32.FLASHWINFO),
                                .hwnd = win_hwnd,
                                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                .uCount = 2,
                                .dwTimeout = 0,
                            };
                            _ = w32.FlashWindowEx(&fwi);
                        }
                    }
                },
            }
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            // Update our stored config with the new one.
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;

                // Recreate the background brush from the new config.
                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

                // Refresh DWM chrome (dark/light, caption color) on
                // every live window so a config reload that changes
                // the background color updates the title bar.
                for (self.windows.items) |w| w.onConfigChange();

                // Re-register global hotkeys against the new keybinds.
                for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
                self.global_hotkeys.clearRetainingCapacity();
                global_hotkey.registerGlobalHotkey(self);

                // Update quick terminal config.
                if (self.quick_terminal) |qt| {
                    qt.onConfigChange(&self.config);
                }
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },

        .toggle_maximize => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                        if (w32.IsZoomed(hwnd) != 0) {
                            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        } else {
                            _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                        }
                    }
                },
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // Close the entire window (all tabs), not just one tab.
                    // Confirm first if any tab still has a running process.
                    const win = core_surface.rt_surface.parent_window;
                    if (win.confirmCloseIfNeeded()) win.close();
                },
            }
            return true;
        },

        .open_config => {
            // Sharp's settings panel is its config UI; the file itself is
            // one click away inside it.
            const window: ?*Window = switch (target) {
                .surface => |core_surface| core_surface.rt_surface.parent_window,
                .app => if (self.windows.items.len > 0) self.windows.items[0] else null,
            };
            if (window) |w| {
                if (!w.is_quick_terminal) {
                    w.openSettings();
                    return true;
                }
            }
            return self.openConfigFile(value);
        },

        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .open_url => {
            // Deferred via App.WM_APP_OPEN_URL; the handler owns the copy.
            if (value.url.len == 0) return true;
            const hwnd = self.msg_hwnd orelse return true;
            const alloc = self.core_app.alloc;
            const owned = alloc.dupe(u8, value.url) catch {
                log.warn("oom allocating url to open", .{});
                return true;
            };
            const request = alloc.create(App.OpenUrlRequest) catch {
                alloc.free(owned);
                return true;
            };
            request.* = .{ .kind = value.kind, .url = owned };
            if (w32.PostMessageW(hwnd, App.WM_APP_OPEN_URL, @intFromPtr(request), 0) == 0) {
                request.deinit(alloc);
            }
            return true;
        },

        .mouse_over_link => {
            // Show the hovered URL in a small status bubble at the bottom
            // of the surface (cursor shape is handled by mouse_shape).
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseOverLink(value.url);
                },
            }
            return true;
        },

        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    find_bar.setSearchActive(core_surface.rt_surface, true, value.needle);
                },
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    find_bar.setSearchActive(core_surface.rt_surface, false, "");
                },
            }
            return true;
        },

        .search_total => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    find_bar.setSearchTotal(core_surface.rt_surface, value.total);
                },
            }
            return true;
        },

        .search_selected => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    find_bar.setSearchSelected(core_surface.rt_surface, value.selected);
                },
            }
            return true;
        },

        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },

        .new_tab => {
            // Add a new tab to the parent window of the focused surface.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const parent = core_surface.rt_surface.parent_window;
                    _ = parent.addTab() catch |err| {
                        log.err("failed to add new tab err={}", .{err});
                    };
                },
            }
            return true;
        },

        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.closeTabMode(
                        value,
                        core_surface.rt_surface,
                    );
                },
            }
            return true;
        },

        .goto_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    _ = core_surface.rt_surface.parent_window.selectTab(value);
                },
            }
            return true;
        },

        .set_tab_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.onTabTitleChanged(
                        core_surface.rt_surface,
                        value.title,
                    );
                },
            }
            return true;
        },

        .set_window_title => {
            switch (target) {
                .app => return false,
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.setWindowTitle(value.title);
                },
            }
            return true;
        },

        .move_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.moveTab(value.amount);
                },
            }
            return true;
        },

        .move_tab_to_new_window => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| try core_surface.rt_surface.parent_window
                    .moveTabToNewWindow(core_surface.rt_surface),
            };
        },

        .toggle_tab_overview => {
            return switch (target) {
                .app => false,
                .surface => |surface| surface.rt_surface.parent_window.requestToggleTabOverview(),
            };
        },

        .initial_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Convert client size to window size (accounts for
                        // title bar, borders, scrollbar).
                        var rect = w32.RECT{
                            .left = 0,
                            .top = 0,
                            .right = @intCast(value.width),
                            .bottom = @intCast(value.height),
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h,
                            null,
                            0,
                            0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },

        .resize_window => {
            return switch (target) {
                .app => false,
                .surface => |core| core.rt_surface.parent_window.resizeSurface(core.rt_surface, value),
            };
        },

        .reload_config => {
            // Reload config and push to the core, which triggers
            // config_change actions on all surfaces.
            const alloc = self.core_app.alloc;
            if (value.soft) {
                // Soft reload: re-apply existing config (for conditional state changes)
                self.core_app.updateConfig(self, &self.config) catch |err| {
                    log.err("soft config reload error: {}", .{err});
                };
            } else {
                // Hard reload: read config from disk
                var new_config = App.Config.load(alloc) catch |err| {
                    log.err("failed to reload config: {}", .{err});
                    return true;
                };
                defer new_config.deinit();
                self.core_app.updateConfig(self, &new_config) catch |err| {
                    log.err("config update error: {}", .{err});
                };
            }
            return true;
        },

        .show_child_exited => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const exit_code = value.exit_code;
                    if (exit_code != 0) {
                        // Show a message box including the actual exit code.
                        const hwnd_val = core_surface.rt_surface.parent_window.hwnd;
                        var utf8_buf: [128]u8 = undefined;
                        const msg_utf8 = std.mem.print(
                            &utf8_buf,
                            "The shell process exited with code {d}.",
                            .{exit_code},
                        ) catch "The shell process exited unexpectedly.";

                        var utf16_buf: [256]u16 = undefined;
                        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, msg_utf8) catch {
                            _ = w32.MessageBoxW(
                                hwnd_val,
                                std.unicode.utf8ToUtf16LeStringLiteral("The shell process exited unexpectedly."),
                                std.unicode.utf8ToUtf16LeStringLiteral(brand.name),
                                w32.MB_ICONWARNING,
                            );
                            return true;
                        };
                        utf16_buf[utf16_len] = 0;
                        _ = w32.MessageBoxW(
                            hwnd_val,
                            @ptrCast(&utf16_buf),
                            std.unicode.utf8ToUtf16LeStringLiteral(brand.name),
                            w32.MB_ICONWARNING,
                        );
                    }
                },
            }
            return true;
        },

        .toggle_window_decorations => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleWindowDecorations();
                },
            }
            return true;
        },

        .close_all_windows => {
            // Close all surfaces by posting WM_CLOSE to each.
            // The core tracks surfaces; iterate via quit.
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .toggle_background_opacity => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        const current_ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                        if (current_ex & w32.WS_EX_LAYERED != 0) {
                            // Remove layered style (restore full opacity).
                            // Clearing WS_EX_LAYERED is not repainted
                            // automatically — without an explicit redraw the
                            // window stays translucent until the next
                            // repaint (e.g. a later focus change).
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
                            _ = w32.RedrawWindow(
                                h,
                                null,
                                null,
                                w32.RDW_ERASE | w32.RDW_INVALIDATE | w32.RDW_FRAME | w32.RDW_ALLCHILDREN,
                            );
                        } else {
                            // Apply opacity from config
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
                            const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
                            _ = w32.SetLayeredWindowAttributes(h, 0, alpha, w32.LWA_ALPHA);
                        }
                    }
                },
            }
            return true;
        },

        .goto_window => {
            // With no tab bar, each "tab" is a window — goto_window
            // and goto_tab behave the same. Just acknowledge.
            return true;
        },

        .reset_window_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Reset to default 800x600
                        var rect = w32.RECT{
                            .left = 0,
                            .top = 0,
                            .right = 800,
                            .bottom = 600,
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h,
                            null,
                            0,
                            0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },

        .copy_title_to_clipboard => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Get the window title and put it on the clipboard
                        var wbuf: [512]u16 = undefined;
                        const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, @intCast(wbuf.len)));
                        if (wlen > 0) {
                            var utf8_buf: [1024]u8 = undefined;
                            const utf8_len = wide_string.toUtf8(&utf8_buf, wbuf[0..wlen]);
                            if (utf8_len > 0) {
                                // Copy to clipboard via the core surface
                                const alloc = self.core_app.alloc;
                                const text = alloc.dupeSentinel(u8, utf8_buf[0..utf8_len], 0) catch return true;
                                defer alloc.free(text);
                                core_surface.rt_surface.setClipboard(
                                    .standard,
                                    &.{.{ .mime = "text/plain", .data = text }},
                                    false,
                                ) catch {};
                            }
                        }
                    }
                },
            }
            return true;
        },

        .export_terminal_io => return self.exportTerminalIo(target, value.contents),

        .render => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.core_surface_ready) {
                        core_surface.rt_surface.core_surface.renderer_thread.wakeup.notify() catch {};
                    }
                },
            }
            return true;
        },

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .key_sequence,
        .key_table,
        .cell_size,
        .readonly,
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => return true,

        .renderer_health => {
            // Surface a warning when the GPU renderer degrades so a frozen
            // display is explainable (macOS shows an in-window message).
            switch (value) {
                .healthy => {},
                .unhealthy => {
                    self.notif_desktop_surface_id = 0;
                    self.showDesktopNotificationText(
                        "Renderer Unhealthy",
                        "The GPU renderer is in an unhealthy state; terminal output may stop updating.",
                    );
                },
            }
            return true;
        },

        .progress_report => {
            // Reflect shell/TUI progress (OSC 9;4) on the taskbar button, the
            // Windows equivalent of the macOS Dock progress. Gated on
            // progress-style; the win32 apprt has no progress bar of its own.
            if (!self.config.@"progress-style") return true;
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const hwnd = core_surface.rt_surface.parent_window.hwnd orelse
                        return true;
                    const tb = self.taskbarList() orelse return true;
                    switch (value.state) {
                        .remove => tb.SetProgressState(hwnd, w32.TBPF_NOPROGRESS),
                        .indeterminate => tb.SetProgressState(hwnd, w32.TBPF_INDETERMINATE),
                        .set => {
                            tb.SetProgressState(hwnd, w32.TBPF_NORMAL);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .@"error" => {
                            tb.SetProgressState(hwnd, w32.TBPF_ERROR);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .pause => {
                            tb.SetProgressState(hwnd, w32.TBPF_PAUSED);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                    }
                },
            }
            return true;
        },

        .color_change => {
            // Track terminal background color changes (OSC 10/11) so the
            // class background brush matches. The renderer paints the
            // client area via OpenGL — the brush only affects the brief
            // flash on resize before the renderer catches up.
            if (value.kind != .background) return true;
            if (self.bg_brush) |old_brush| {
                _ = w32.DeleteObject(@ptrCast(old_brush));
            }
            self.bg_brush = w32.CreateSolidBrush(w32.RGB(value.r, value.g, value.b));
            // SetClassLongPtrW propagates the new brush to all existing
            // windows of the class, not just future ones.
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (self.bg_brush) |b| {
                        _ = w32.SetClassLongPtrW(
                            h,
                            w32.GCLP_HBRBACKGROUND,
                            @intCast(@intFromPtr(b)),
                        );
                    }
                }
            }
            return true;
        },

        .size_limit => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.min_track_w = @intCast(value.min_width);
                    win.min_track_h = @intCast(value.min_height);
                    win.max_track_w = @intCast(value.max_width);
                    win.max_track_h = @intCast(value.max_height);
                },
            }
            return true;
        },

        .toggle_visibility => {
            // Hide all visible top-level Ghostty windows; if any are
            // already hidden, show + restore them. Equivalent to macOS
            // NSApp hide / show.
            var any_visible = false;
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (w32.IsWindowVisible_(h) != 0) {
                        any_visible = true;
                        break;
                    }
                }
            }
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (any_visible) {
                        _ = w32.ShowWindow(h, w32.SW_HIDE);
                    } else {
                        _ = w32.ShowWindow(h, w32.SW_SHOWNOACTIVATE);
                    }
                }
            }
            // The quick terminal manages its own visibility separately.
            return true;
        },

        .float_window => {
            // Toggle WS_EX_TOPMOST so the window stays above non-topmost
            // windows. Equivalent to macOS NSWindow.level = .floating.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
                    _ = w32.SetWindowPos(
                        win_hwnd,
                        insert_after,
                        0,
                        0,
                        0,
                        0,
                        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
                    );
                },
            }
            return true;
        },

        .command_finished => {
            // The core emits this for every finished command; all gating is
            // apprt-side (config notify-on-command-finish*), matching the
            // GTK and macOS runtimes.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    switch (self.config.@"notify-on-command-finish") {
                        .never => return true,
                        .unfocused => if (core_surface.focused) return true,
                        .always => {},
                    }
                    if (value.duration.lte(self.config.@"notify-on-command-finish-after"))
                        return true;

                    const act = self.config.@"notify-on-command-finish-action";
                    if (act.bell) {
                        _ = w32.MessageBeep(0xFFFFFFFF);
                        // Flash the taskbar button when backgrounded so the
                        // bell is visible too.
                        if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                            if (w32.GetForegroundWindow() != win_hwnd) {
                                var fwi: w32.FLASHWINFO = .{
                                    .cbSize = @sizeOf(w32.FLASHWINFO),
                                    .hwnd = win_hwnd,
                                    .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                    .uCount = 3,
                                    .dwTimeout = 0,
                                };
                                _ = w32.FlashWindowEx(&fwi);
                            }
                        }
                    }
                    if (act.notify) {
                        const title: []const u8 = if (value.exit_code) |code|
                            (if (code == 0) "Command Succeeded" else "Command Failed")
                        else
                            "Command Finished";
                        var body_buf: [128]u8 = undefined;
                        const body: []const u8 = if (value.exit_code) |code|
                            std.mem.print(
                                &body_buf,
                                "Command took {f} and exited with code {d}.",
                                .{ value.duration.round(std.time.ns_per_ms), code },
                            ) catch "Command finished."
                        else
                            std.mem.print(
                                &body_buf,
                                "Command took {f}.",
                                .{value.duration.round(std.time.ns_per_ms)},
                            ) catch "Command finished.";
                        self.notif_desktop_surface_id = core_surface.id;
                        self.showDesktopNotificationText(title, body);
                    }
                },
            }
            return true;
        },

        .mouse_visibility => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const visible = value == .visible;
                    core_surface.rt_surface.mouse_visible = visible;
                    // Force the next WM_SETCURSOR to apply the new state
                    // by issuing SetCursor immediately if the cursor is
                    // currently in our client area.
                    if (!visible) {
                        _ = w32.SetCursor(null);
                    } else if (core_surface.rt_surface.current_cursor) |c| {
                        _ = w32.SetCursor(c);
                    }
                },
            }
            return true;
        },

        .present_terminal => {
            // Raise the window containing the target surface and select
            // its tab. Restores from minimized/iconic state if necessary.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    if (win.hwnd) |hwnd| {
                        // ShowWindow(SW_RESTORE) brings back from minimize.
                        _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        _ = w32.SetForegroundWindow(hwnd);
                        // Make sure the tab containing this surface is active.
                        if (win.findTabIndex(core_surface.rt_surface)) |idx| {
                            if (idx != win.active_tab) win.selectTabIndex(idx);
                        }
                        // Focus the surface's child HWND.
                        if (core_surface.rt_surface.hwnd) |sh| {
                            _ = w32.SetFocus(sh);
                        }
                    }
                },
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const dir: SplitTree(Surface).Split.Direction = switch (value) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    };
                    splits.newSplit(core_surface.rt_surface.parent_window, dir) catch |err| {
                        log.err("failed to create split: {}", .{err});
                    };
                },
            }
            return true;
        },

        .goto_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    splits.gotoSplit(core_surface.rt_surface.parent_window, value);
                },
            }
            return true;
        },

        .resize_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    splits.resizeSplit(core_surface.rt_surface.parent_window, value);
                },
            }
            return true;
        },

        .equalize_splits => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    splits.equalizeSplits(core_surface.rt_surface.parent_window);
                },
            }
            return true;
        },

        .toggle_split_zoom => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    splits.toggleSplitZoom(core_surface.rt_surface.parent_window);
                },
            }
            return true;
        },

        .prompt_title => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| blk: {
                    const window = core_surface.rt_surface.parent_window;
                    switch (value) {
                        .surface, .tab => tab_rename.startTabRename(window, window.active_tab),
                        .window => tab_rename.startWindowRename(window),
                    }
                    break :blk true;
                },
            };
        },

        // Sharp publishes no releases to check against.
        .check_for_updates => return false,

        .toggle_command_palette => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const active = core_surface.rt_surface.palette_active;
                    command_palette.setCommandPaletteActive(core_surface.rt_surface, !active);
                },
            }
            return true;
        },

        .toggle_quick_terminal => {
            if (self.quick_terminal) |qt| {
                qt.toggle();
            } else {
                const qt = QuickTerminal.init(self) catch |err| {
                    log.err("failed to create quick terminal: {}", .{err});
                    return true;
                };
                self.quick_terminal = qt;
                qt.toggle();
            }
            return true;
        },

        .selection_changed => {
            // Win32 has no primary-selection clipboard to keep in sync (that
            // is an X11/Wayland concept), so there is nothing to do when the
            // core selection changes. Acknowledge the notification, mirroring
            // the GTK apprt which also treats selection_changed as a no-op.
            return true;
        },

        // Keep this exhaustive so upstream action additions require review.
    }
}
