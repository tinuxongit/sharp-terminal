//! The Windows messages a Sharp window receives (its frame and caption,
//! the tab strip and sidebar's mouse and keys, sizing, DPI, closing)
//! and where each goes.
const std = @import("std");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const tab_sidebar = @import("tab_sidebar.zig");
const SearchField = @import("SearchField.zig");
const workspace = @import("workspace.zig");
const tab_rename = @import("tab_rename.zig");
const splits = @import("splits.zig");
const log = std.log.scoped(.win32);
const Window = @import("Window.zig");
const strip_mouse = @import("strip_mouse.zig");

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
        Window.WM_TOGGLE_TAB_OVERVIEW => {
            window.tab_overview.toggle(window) catch |err| {
                log.warn("unable to open tab overview err={}", .{err});
            };
            return 0;
        },
        Window.WM_REFRESH_TAB_OVERVIEW => {
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
            if (wparam == Window.SIDEBAR_TIMER_ID) {
                if (window.sidebarMode()) {
                    workspace.refreshServers(window);
                    window.sidebar_ticks +%= 1;
                    if (window.sidebar_ticks % (60_000 / Window.SIDEBAR_TIMER_MS) == 0) window.invalidateTabBar();
                }
                return 0;
            }
            if (wparam == Window.RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, Window.RESIZE_OVERLAY_TIMER_ID);
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
            const button = Window.captionButtonAt(wparam);
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
            if (Window.captionButtonAt(wparam)) |button| {
                window.strip_pressed = button;
                window.invalidateTabBar();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCLBUTTONUP => {
            const pressed = window.strip_pressed;
            window.strip_pressed = .none;
            if (Window.captionButtonAt(wparam)) |button| {
                window.invalidateTabBar();
                if (pressed.eql(button)) window.pressCaptionButton(button);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_NCLBUTTONDBLCLK => {
            if (Window.captionButtonAt(wparam) != null) return 0;
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
                strip_mouse.handleTabBarClick(window, @truncate(x), @truncate(y));
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
                strip_mouse.handleTabBarRightClick(window, x, y);
                return 0;
            }
            switch (workspace.sidebarTarget(window, x, y)) {
                .tab, .close => |i| {
                    strip_mouse.showTabMenu(window, i, x, y);
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
                .tab, .tab_close => |i| strip_mouse.closeTabFromStrip(window, i),
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
                            strip_mouse.moveTabTo(window, from, to);
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
                        strip_mouse.moveTabTo(window, from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                strip_mouse.handleTabBarMouseMove(window, @truncate(x), @truncate(y));
            } else {
                strip_mouse.releaseFrozenTabWidth(window);
                if (workspace.inSidebar(window, x, y)) strip_mouse.trackMouseLeave(window);
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
            strip_mouse.handleTabBarMouseLeave(window);
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
