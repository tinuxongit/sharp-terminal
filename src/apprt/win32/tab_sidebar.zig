//! Tabs as a list beside the terminal (`window-tab-bar-position = sidebar`):
//! a search box, then sections for where shells run (local, WSL, SSH
//! servers), groups for each folder (or server), and the tabs themselves.
//! Layout and painting only; Window handles input.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const profiles = @import("profiles.zig");
const SearchField = @import("SearchField.zig");
const ai_usage = @import("ai_usage.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

/// Sizes in pixels at 96 DPI.
pub const default_width = 260.0;
pub const min_width = 180.0;
pub const max_width = 600.0;
const pad = 10.0;
const search_height = 34.0;
const section_height = 30.0;
const group_height = 30.0;
const item_height = 32.0;
const item_indent = 22.0;
const icon_size = 16.0;
const corner = 6.0;
const dot_size = 8.0;
const side_column = 34.0;
const button_size = 24.0;
const resize_grip = 5.0;

const icon_folder = 0xE8B7;
const icon_folder_open = 0xE838;
const icon_server = 0xE774;
const icon_close = 0xE8BB;
const icon_add = 0xE710;
const icon_chevron_down = 0xE70D;
const arrow_width = 18.0;

/// Bell red, as in the sidebar this mirrors.
const attention_red: Rgb = .{ .r = 0xE5, .g = 0x48, .b = 0x3E };

pub const Section = enum { local, wsl, servers };

pub const Item = struct {
    tab: usize,
    /// The title, converted to UTF-8 for drawing and search.
    title: []const u8,
    icon: ?w32.HICON,
    section: Section,
    /// What the tab is grouped by: its folder's full path, or the SSH
    /// host for servers.
    group: []const u8,
    /// How the group is labelled: the folder's name, or the host.
    group_label: []const u8,
    age_ms: u64,
    attention: bool,
};

pub const Target = union(enum) {
    none,
    search,
    /// The right edge: dragging it resizes the sidebar.
    resize,
    tab: usize,
    close: usize,
    /// A group header, named by the first tab in it: toggles collapse.
    group: usize,
    /// The "+" on a group header: a new tab with the default shell in that
    /// folder.
    group_new: usize,
    /// The arrow beside it: the shell menu, for a tab in that folder.
    group_menu: usize,
    /// A section title, which shows its buttons while hovered.
    section: Section,
    /// The "+" on a section title: a new tab in a folder the user picks.
    section_new: Section,
    /// The arrow beside it: the shell menu then the folder picker, or for
    /// Servers the server menu.
    section_menu: Section,
    /// The box Servers' "+" opens, where an address is typed.
    server_field,
    /// The AI section's title: folds or unfolds it.
    usage_title,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const Spots = @import("spots.zig").Spots(Target, 200);

pub const Fonts = struct {
    item: ?*anyopaque = null,
    item_strong: ?*anyopaque = null,
    small: ?*anyopaque = null,
    icons: ?*anyopaque = null,
    icons_small: ?*anyopaque = null,
    icons_tiny: ?*anyopaque = null,

    pub fn init(hdc: w32.HDC, scale: f32) Fonts {
        const ui = canvas_mod.jetbrains_mono;
        const icon_face = canvas_mod.iconFace(hdc);
        const f = canvas_mod.createFont;
        return .{
            .item = f(13, scale, ui, w32.FW_NORMAL, .cleartype),
            .item_strong = f(13, scale, ui, w32.FW_BOLD, .cleartype),
            .small = f(12, scale, ui, w32.FW_NORMAL, .cleartype),
            .icons = f(14, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_small = f(9, scale, icon_face, w32.FW_NORMAL, .grayscale),
            .icons_tiny = f(7, scale, icon_face, w32.FW_NORMAL, .grayscale),
        };
    }

    pub fn deinit(self: *Fonts) void {
        inline for (.{ &self.item, &self.item_strong, &self.small, &self.icons, &self.icons_small, &self.icons_tiny }) |font| {
            if (font.*) |f| _ = w32.DeleteObject(f);
            font.* = null;
        }
    }
};

pub const State = struct {
    items: []const Item,
    active: usize,
    hover: Target,
    search: *const SearchField,
    window_focused: bool,
    scroll: i32,
    /// Group keys the user folded away.
    collapsed: []const []const u8,
    /// The tab being dragged, drawn as lifted.
    dragging: ?usize = null,
    /// The arrow whose menu is open, which stays lit.
    pressed: Target = .none,
    /// Whether WSL is installed, so its section shows even when empty.
    has_wsl: bool = false,
    /// The address box under Servers, while open.
    server_field: ?*const SearchField = null,
    /// Claude's, Codex's and OpenCode's usage, shown at the foot.
    usage: ai_usage.Snapshot = .{},
    /// Whether the AI section is folded to its title.
    usage_folded: bool = false,
    /// Unix seconds, for "resets in".
    now_s: i64 = 0,
};

/// How a folded group is remembered: the same folder can hold both local
/// and WSL tabs, folded separately.
pub fn collapseKey(buf: []u8, section: Section, group: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}", .{ @tagName(section), group }) catch group;
}

pub fn sameGroup(a: []const u8, b: []const u8) bool {
    // Windows paths ignore case.
    return std.ascii.eqlIgnoreCase(a, b);
}

fn px(value: f32, scale: f32) i32 {
    return @intFromFloat(@round(value * scale));
}

const Painter = struct {
    c: Canvas,
    s: f32,
    palette: tab_strip.Palette,
    fonts: Fonts,
    state: State,
    spots: *Spots,
    list_top: i32,
    /// Where the list ends: the AI section is pinned below it.
    list_bottom: i32,

    fn px(self: Painter, value: f32) i32 {
        return @intFromFloat(@round(value * self.s));
    }
};

/// Paint the sidebar into `c`, which covers exactly the sidebar, and
/// return how far its list can scroll.
pub fn paint(c: Canvas, scale: f32, palette: tab_strip.Palette, fonts: Fonts, state: State, spots: *Spots) i32 {
    spots.len = 0;
    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = c.height }, palette.strip);

    const search_rect: w32.RECT = .{ .left = px(pad, scale), .top = px(pad, scale), .right = c.width - px(pad, scale), .bottom = px(pad + search_height, scale) };
    const list_top = search_rect.bottom + px(pad, scale);
    const list_bottom = c.height - usageHeight(state, scale);
    var p: Painter = .{ .c = c, .s = scale, .palette = palette, .fonts = fonts, .state = state, .spots = spots, .list_top = list_top, .list_bottom = list_bottom };

    // The list first, so the search area covers what scrolls under it.
    var y = list_top - state.scroll;
    for ([_]Section{ .local, .wsl, .servers }) |section| {
        // Empty sections stay, so their buttons can open the first tab.
        const always = state.search.len == 0 and (section != .wsl or state.has_wsl);
        if (!always and !sectionHasItems(state, section)) continue;
        y = paintSection(&p, section, y);
        if (section == .servers) {
            if (state.server_field) |field| y = paintServerField(&p, field, y);
        }
        // Groups in the order their first tab appears.
        for (state.items, 0..) |first, i| {
            if (first.section != section or !visible(state, first)) continue;
            if (seenGroupBefore(state, state.items[0..i], first)) continue;
            const folded = isCollapsed(state, first);
            y = paintGroup(&p, first, folded, y);
            if (folded) continue;
            for (state.items) |item| {
                if (item.section != section or !visible(state, item) or !sameGroup(item.group, first.group)) continue;
                y = paintItem(&p, item, y);
            }
        }
    }
    const content_height = y + state.scroll - list_top;

    paintUsage(&p);
    c.fill(.{ .left = 0, .top = 0, .right = c.width, .bottom = list_top }, palette.strip);
    state.search.paint(c, search_rect, scale, .{
        .fill = palette.strip.mix(palette.contrast, 0.06),
        .hover = palette.hover,
        .focused = palette.hover.mix(palette.contrast, 0.05),
        .text = palette.text,
        .text_dim = palette.text_dim,
        .font = fonts.item,
        .icon_font = fonts.icons_small,
        .placeholder = profiles.data.sidebar.search_placeholder,
    }, state.hover.eql(.search), state.window_focused);
    spots.add(search_rect, .search);

    // The grip goes last so it wins over rows near the edge.
    const grip: w32.RECT = .{ .left = c.width - px(resize_grip, scale), .top = 0, .right = c.width, .bottom = c.height };
    if (state.hover.eql(.resize)) c.fill(.{ .left = c.width - px(2, scale), .top = 0, .right = c.width, .bottom = c.height }, palette.separator);
    spots.add(grip, .resize);

    return @max(0, content_height - (list_bottom - list_top));
}

const usage_row_height = 22.0;
const usage_bar_height = 4.0;
const max_usage_rows = 2 * ai_usage.max_windows + 2;
const icon_chevron_right = 0xE76C;

/// A row's label: the tool, then what it counts, as in "Claude · 5 h".
const UsageLabel = struct { tool: []const u8, what: []const u8 };

const UsageRow = union(enum) {
    window: struct { label: UsageLabel, window: ai_usage.Window },
    spend: struct { label: UsageLabel, spend: ai_usage.Spend },
    note: UsageLabel,
};

/// The rows the AI section shows, in order; none when it is folded.
/// Labels point into `state`, so it must outlive the rows.
fn usageRows(state: *const State, out: *[max_usage_rows]UsageRow) []const UsageRow {
    const text = profiles.data.sidebar.ai;
    const u = &state.usage;
    var n: usize = 0;
    for ([_]struct { []const u8, *const ai_usage.Plan }{ .{ text.claude, &u.claude }, .{ text.codex, &u.codex } }) |tool| {
        const name, const plan = tool;
        if (!plan.found) continue;
        var shown = false;
        for (&plan.windows) |*slot| {
            const w = if (slot.*) |*w| w else continue;
            const what = if (w.kind == .model) w.model() else windowName(w.minutes);
            out[n] = .{ .window = .{ .label = .{ .tool = name, .what = what }, .window = w.* } };
            n += 1;
            shown = true;
        }
        // Windows the user switched off leave nothing, not a note.
        if (!shown and !plan.hid_some) {
            out[n] = .{ .note = .{ .tool = name, .what = if (plan.answered) text.no_plan_limits else text.checking } };
            n += 1;
        }
    }
    if (u.opencode_found) {
        if (u.opencode_today) |s| {
            out[n] = .{ .spend = .{ .label = .{ .tool = text.opencode, .what = text.today }, .spend = s } };
            n += 1;
        }
        if (u.opencode_week) |s| {
            out[n] = .{ .spend = .{ .label = .{ .tool = text.opencode, .what = text.week }, .spend = s } };
            n += 1;
        }
    }
    return out[0..n];
}

/// "5 h", "week" or "month" for the windows plans use, else hours or days.
fn windowName(minutes: u32) []const u8 {
    const text = profiles.data.sidebar.ai;
    return switch (minutes) {
        5 * 60 => text.five_hours,
        7 * 24 * 60 => text.week,
        28 * 24 * 60...31 * 24 * 60 => text.month,
        else => "",
    };
}

fn usageHeight(state: State, scale: f32) i32 {
    var rows: [max_usage_rows]UsageRow = undefined;
    const shown = usageRows(&state, &rows);
    if (shown.len == 0) return 0;
    var h: f32 = section_height + pad;
    if (!state.usage_folded) {
        for (shown) |row| h += usage_row_height + @as(f32, if (row == .window) usage_bar_height + 4 else 0);
    }
    return px(h, scale);
}

/// The AI section, pinned under the list: plan windows as bars, OpenCode's
/// spending as figures. Clicking its title folds it to just the title.
fn paintUsage(p: *Painter) void {
    var rows: [max_usage_rows]UsageRow = undefined;
    const shown = usageRows(&p.state, &rows);
    if (shown.len == 0) return;
    const c = p.c;
    c.fill(.{ .left = 0, .top = p.list_bottom, .right = c.width, .bottom = c.height }, p.palette.strip);
    var y = p.list_bottom;

    // The title, drawn as the list's are, with an arrow that tells folded
    // from open.
    const title = profiles.data.sidebar.ai.title;
    const h = p.px(section_height);
    const left = p.px(pad + 6);
    const right = c.width - p.px(pad + 6);
    const header: w32.RECT = .{ .left = p.px(pad), .top = y, .right = c.width - p.px(pad), .bottom = y + h };
    const hovered = p.state.hover.eql(.usage_title);
    if (hovered) c.fillRounded(header, p.px(corner), p.palette.hover);
    c.text(.{ .left = left, .top = y, .right = right, .bottom = y + h }, title, p.fonts.small, if (hovered) p.palette.text else p.palette.text_dim, .left);
    const arrow_w = p.px(icon_size);
    c.glyph(.{ .left = right - arrow_w, .top = y, .right = right, .bottom = y + h }, if (p.state.usage_folded) icon_chevron_right else icon_chevron_down, p.fonts.icons_tiny, p.palette.text_dim);
    const rule_left = left + c.textWidth(title, p.fonts.small) + p.px(10);
    const rule_right = right - arrow_w - p.px(6);
    const mid = y + @divTrunc(h, 2);
    if (rule_right > rule_left) c.fill(.{ .left = rule_left, .top = mid, .right = rule_right, .bottom = mid + 1 }, p.palette.separator);
    p.spots.add(header, .usage_title);
    y += h;
    if (p.state.usage_folded) return;

    const row_h = p.px(usage_row_height);
    for (shown) |row| {
        var value_buf: [48]u8 = undefined;
        const label, const value = switch (row) {
            .window => |w| .{ w.label, windowText(&value_buf, w.window, p.state.now_s) },
            .spend => |s| .{ s.label, spendText(&value_buf, s.spend) },
            .note => |l| .{ l, "" },
        };
        var label_buf: [96]u8 = undefined;
        const label_text = if (label.what.len == 0)
            label.tool
        else
            std.fmt.bufPrint(&label_buf, "{s} \u{00B7} {s}", .{ label.tool, label.what }) catch label.tool;
        // The figure keeps its room; a narrow sidebar cuts the label.
        const line: w32.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + row_h };
        const value_w = if (value.len > 0) c.textWidth(value, p.fonts.small) + p.px(8) else 0;
        c.text(.{ .left = left, .top = y, .right = @max(left, right - value_w), .bottom = y + row_h }, label_text, p.fonts.small, p.palette.text_dim, .left);
        if (value.len > 0) c.text(line, value, p.fonts.small, p.palette.text, .right);
        y += row_h;
        if (row == .window) {
            const bar_h = p.px(usage_bar_height);
            const track: w32.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + bar_h };
            c.fillRounded(track, @divTrunc(bar_h, 2), p.palette.strip.mix(p.palette.contrast, 0.12));
            const percent = row.window.window.percent;
            const fill_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(right - left)) * percent / 100));
            if (fill_w > 0) {
                const ai = profiles.data.sidebar.ai;
                const color: Rgb = if (percent >= @as(f32, @floatFromInt(ai.warn_percent)))
                    .{ .r = ai.warning_color.r, .g = ai.warning_color.g, .b = ai.warning_color.b }
                else
                    p.palette.text_dim;
                c.fillRounded(.{ .left = left, .top = y, .right = left + @max(fill_w, bar_h), .bottom = y + bar_h }, @divTrunc(bar_h, 2), color);
            }
            y += bar_h + p.px(4);
        }
    }
}

/// "42% · 2h 31m": how much is used and how long until it resets.
fn windowText(buf: []u8, w: ai_usage.Window, now_s: i64) []const u8 {
    const percent: u32 = @intFromFloat(@round(w.percent));
    if (w.resets_at == 0 or w.resets_at <= now_s) return std.fmt.bufPrint(buf, "{d}%", .{percent}) catch "";
    const minutes: u64 = @intCast(@divFloor(w.resets_at - now_s + 59, 60));
    const days = minutes / (24 * 60);
    const hours = (minutes / 60) % 24;
    return if (days > 0)
        std.fmt.bufPrint(buf, "{d}% \u{00B7} {d}d {d}h", .{ percent, days, hours }) catch ""
    else if (hours > 0)
        std.fmt.bufPrint(buf, "{d}% \u{00B7} {d}h {d}m", .{ percent, hours, minutes % 60 }) catch ""
    else
        std.fmt.bufPrint(buf, "{d}% \u{00B7} {d}m", .{ percent, minutes }) catch "";
}

/// "$1.20 · 248k": spent, and tokens read and written.
fn spendText(buf: []u8, s: ai_usage.Spend) []const u8 {
    return if (s.tokens >= 1_000_000)
        std.fmt.bufPrint(buf, "${d:.2} \u{00B7} {d:.1}M", .{ s.cost_usd, @as(f64, @floatFromInt(s.tokens)) / 1_000_000 }) catch ""
    else
        std.fmt.bufPrint(buf, "${d:.2} \u{00B7} {d}k", .{ s.cost_usd, s.tokens / 1000 }) catch "";
}

fn visible(state: State, item: Item) bool {
    const query = state.search.text();
    return query.len == 0 or SearchField.matches(item.title, query) or SearchField.matches(item.group_label, query);
}

fn isCollapsed(state: State, item: Item) bool {
    // Searching shows every match, folded or not.
    if (state.search.len > 0) return false;
    var buf: [300]u8 = undefined;
    const wanted = collapseKey(&buf, item.section, item.group);
    for (state.collapsed) |key| {
        if (sameGroup(key, wanted)) return true;
    }
    return false;
}

fn sectionHasItems(state: State, section: Section) bool {
    for (state.items) |item| {
        if (item.section == section and visible(state, item)) return true;
    }
    return false;
}

fn seenGroupBefore(state: State, earlier: []const Item, item: Item) bool {
    for (earlier) |e| {
        if (e.section == item.section and visible(state, e) and sameGroup(e.group, item.group)) return true;
    }
    return false;
}

fn groupHoldsActive(state: State, group: Item) bool {
    for (state.items) |item| {
        if (item.tab == state.active and item.section == group.section and sameGroup(item.group, group.group)) return true;
    }
    return false;
}

/// A section title followed by a rule to the right edge, and while
/// hovered a "+" and an arrow that open a tab in a chosen folder, or on
/// Servers, on a chosen server.
fn paintSection(p: *Painter, section: Section, y: i32) i32 {
    const title = switch (section) {
        .local => profiles.data.sidebar.local,
        .wsl => profiles.data.sidebar.wsl,
        .servers => profiles.data.sidebar.servers,
    };
    const h = p.px(section_height);
    const left = p.px(pad + 6);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    p.c.text(.{ .left = left, .top = y, .right = row.right, .bottom = y + h }, title, p.fonts.small, p.palette.text_dim, .left);

    const buttons: NewTabButtons = .{ .plus = .{ .section_new = section }, .menu = .{ .section_menu = section } };
    const hovered = p.state.hover.eql(.{ .section = section }) or buttons.lit(p.state);

    const rule_left = left + p.c.textWidth(title, p.fonts.small) + p.px(10);
    const rule_right = (if (hovered) newTabButtonsLeft(p, row) else row.right) - p.px(6);
    const mid = y + @divTrunc(h, 2);
    if (rule_right > rule_left) p.c.fill(.{ .left = rule_left, .top = mid, .right = rule_right, .bottom = mid + 1 }, p.palette.separator);

    p.spots.add(clip(row, p), .{ .section = section });
    if (hovered) paintNewTabButtons(p, row, buttons, p.palette.strip);
    return y + h;
}

/// The box for a server's address, as tall as the search box.
fn paintServerField(p: *Painter, field: *const SearchField, y: i32) i32 {
    const h = p.px(search_height);
    const rect: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    field.paint(p.c, rect, p.s, .{
        .fill = p.palette.strip.mix(p.palette.contrast, 0.06),
        .hover = p.palette.hover,
        .focused = p.palette.hover.mix(p.palette.contrast, 0.05),
        .text = p.palette.text,
        .text_dim = p.palette.text_dim,
        .font = p.fonts.item,
        .icon_font = p.fonts.icons_small,
        .placeholder = profiles.data.sidebar.server_placeholder,
        .icon = icon_server,
    }, false, p.state.window_focused);
    p.spots.add(clip(rect, p), .server_field);
    return y + h + p.px(4);
}

fn paintGroup(p: *Painter, first: Item, folded: bool, y: i32) i32 {
    const h = p.px(group_height);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    const buttons: NewTabButtons = .{ .plus = .{ .group_new = first.tab }, .menu = .{ .group_menu = first.tab } };
    const hovered = p.state.hover.eql(.{ .group = first.tab }) or buttons.lit(p.state);
    if (hovered) p.c.fillRounded(row, p.px(corner), p.palette.hover);

    const active = groupHoldsActive(p.state, first);
    const color = if (active or hovered) p.palette.text else p.palette.text_dim;
    const left = p.px(pad + 6);
    const icon: u16 = if (first.section == .servers) icon_server else if (folded) icon_folder else icon_folder_open;
    p.c.glyph(.{ .left = left, .top = y, .right = left + p.px(icon_size), .bottom = y + h }, icon, p.fonts.icons, color);

    const label_right = (if (hovered) newTabButtonsLeft(p, row) else row.right) - p.px(4);
    p.c.text(.{ .left = left + p.px(icon_size + 8), .top = y, .right = label_right, .bottom = y + h }, first.group_label, if (active) p.fonts.item_strong else p.fonts.item, color, .left);

    p.spots.add(clip(row, p), .{ .group = first.tab });
    // New tabs open in a folder; a server's tabs come from SSH itself.
    if (hovered and first.section != .servers) paintNewTabButtons(p, row, buttons, p.palette.hover);
    return y + h;
}

/// "+" and the shell menu's arrow, one split button as in the strip.
const NewTabButtons = struct {
    plus: Target,
    menu: Target,

    fn lit(self: NewTabButtons, state: State) bool {
        return state.hover.eql(self.plus) or state.hover.eql(self.menu) or state.pressed.eql(self.menu);
    }
};

fn newTabButtonsLeft(p: *Painter, row: w32.RECT) i32 {
    return row.right - p.px(4 + button_size + arrow_width);
}

/// Draw the split button at the right end of `row`, over `under`.
fn paintNewTabButtons(p: *Painter, row: w32.RECT, buttons: NewTabButtons, under: Rgb) void {
    const size = p.px(button_size);
    const top = row.top + @divTrunc(row.bottom - row.top - size, 2);
    const right = row.right - p.px(4);
    const arrow: w32.RECT = .{ .left = right - p.px(arrow_width), .top = top, .right = right, .bottom = top + size };
    const plus: w32.RECT = .{ .left = arrow.left - size, .top = top, .right = arrow.left, .bottom = top + size };
    const on_plus = p.state.hover.eql(buttons.plus);
    const on_arrow = p.state.hover.eql(buttons.menu) or p.state.pressed.eql(buttons.menu);
    if (on_plus or on_arrow) p.c.fillRounded(if (on_plus) plus else arrow, p.px(corner), under.mix(p.palette.contrast, 0.1));
    p.c.glyph(plus, icon_add, p.fonts.icons_small, if (on_plus) p.palette.text else p.palette.text_dim);
    p.c.glyph(arrow, icon_chevron_down, p.fonts.icons_tiny, if (on_arrow) p.palette.text else p.palette.text_dim);
    p.spots.add(clip(plus, p), buttons.plus);
    p.spots.add(clip(arrow, p), buttons.menu);
}

fn paintItem(p: *Painter, item: Item, y: i32) i32 {
    const h = p.px(item_height);
    const row: w32.RECT = .{ .left = p.px(pad), .top = y, .right = p.c.width - p.px(pad), .bottom = y + h };
    const active = item.tab == p.state.active;
    const dragged = p.state.dragging == item.tab;
    const hovered = !dragged and (p.state.hover.eql(.{ .tab = item.tab }) or p.state.hover.eql(.{ .close = item.tab }));
    if (dragged) {
        p.c.fillRounded(row, p.px(corner), p.palette.hover.mix(p.palette.contrast, 0.08));
    } else if (active) {
        p.c.fillRounded(row, p.px(corner), p.palette.active_tab);
    } else if (hovered) {
        p.c.fillRounded(row, p.px(corner), p.palette.hover);
    }

    const icon_left = row.left + p.px(item_indent);
    const size = p.px(icon_size);
    if (item.icon) |icon| {
        p.c.sync();
        _ = w32.DrawIconEx(p.c.hdc, icon_left, y + @divTrunc(h - size, 2), icon, size, size, 0, null, w32.DI_NORMAL);
    }
    const side: w32.RECT = .{ .left = row.right - p.px(side_column), .top = y, .right = row.right - p.px(4), .bottom = y + h };
    const title_color = if (active or hovered or dragged) p.palette.text else p.palette.text_dim;
    p.c.text(.{ .left = icon_left + size + p.px(10), .top = y, .right = side.left - p.px(4), .bottom = y + h }, item.title, p.fonts.item, title_color, .left);

    // The right column shows, in order of priority: close on hover, the
    // bell dot, or how long ago the tab opened.
    const button = p.px(button_size);
    const close: w32.RECT = .{ .left = side.right - button, .top = y + @divTrunc(h - button, 2), .right = side.right, .bottom = y + @divTrunc(h - button, 2) + button };
    if (hovered) {
        if (p.state.hover.eql(.{ .close = item.tab })) p.c.fillRounded(close, @divTrunc(button, 2), p.palette.hover.mix(p.palette.contrast, 0.1));
        p.c.glyph(close, icon_close, p.fonts.icons_small, p.palette.text);
    } else if (item.attention) {
        const d = p.px(dot_size);
        const dot: w32.RECT = .{ .left = side.right - p.px(10) - d, .top = y + @divTrunc(h - d, 2), .right = side.right - p.px(10), .bottom = y + @divTrunc(h - d, 2) + d };
        p.c.fillRounded(dot, @divTrunc(d, 2), attention_red);
    } else {
        var buf: [8]u8 = undefined;
        p.c.text(side, age(&buf, item.age_ms), p.fonts.small, p.palette.text_dim, .right);
    }
    p.spots.add(clip(row, p), .{ .tab = item.tab });
    // Added after the row so it wins the hit test.
    if (hovered) p.spots.add(clip(close, p), .{ .close = item.tab });
    return y + h;
}

/// Rows that scrolled under the search box or the AI section can't be
/// clicked there.
fn clip(rect: w32.RECT, p: *const Painter) w32.RECT {
    var r = rect;
    r.top = @max(r.top, p.list_top);
    r.bottom = @min(r.bottom, p.list_bottom);
    if (r.bottom < r.top) r.bottom = r.top;
    return r;
}

/// "now", "5m", "3h", "2d" or "1w", like the list this mirrors.
fn age(buf: []u8, ms: u64) []const u8 {
    const minutes = ms / 60_000;
    if (minutes < 1) return "now";
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "";
    const hours = minutes / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "";
    const days = hours / 24;
    if (days < 7) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
    return std.fmt.bufPrint(buf, "{d}w", .{days / 7}) catch "";
}
