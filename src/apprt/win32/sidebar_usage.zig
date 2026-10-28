//! The tab sidebar's AI section, pinned at its foot: a card per tool
//! (Claude Code, Codex, OpenCode) with its icon and name, and for each
//! plan window how much is left, a bar, and when it resets; OpenCode's
//! spending as figures. Clicking the section's title folds it.
const std = @import("std");
const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const tab_strip = @import("tab_strip.zig");
const profiles = @import("profiles.zig");
const ai_usage = @import("ai_usage.zig");
const tab_sidebar = @import("tab_sidebar.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

/// Sizes in pixels at 96 DPI.
const pad = 10.0;
const title_height = 30.0;
const card_gap = 8.0;
const card_pad = 10.0;
const card_corner = 8.0;
const header_height = 22.0;
const icon_size = 16.0;
const line_height = 18.0;
const sub_height = 16.0;
const bar_height = 4.0;
const bar_gap = 3.0;
const row_gap = 8.0;
const chevron_down = 0xE70D;
const chevron_right = 0xE76C;

/// What the section shows.
pub const View = struct {
    usage: *const ai_usage.Snapshot,
    folded: bool,
    title_hovered: bool,
    /// Unix seconds, for "resets in".
    now_s: i64,
    /// Claude Code's, Codex's and OpenCode's program icons, where they
    /// have one.
    icons: [3]?w32.HICON = @splat(null),
};

/// Where and with what to paint; without it walk() only measures.
const Paint = struct {
    c: Canvas,
    palette: tab_strip.Palette,
    fonts: tab_sidebar.Fonts,
    spots: *tab_sidebar.Spots,
};

const Row = union(enum) {
    /// A plan window, the whole plan's or a single model's.
    window: struct { window: *const ai_usage.Window },
    spend: struct { what: []const u8, spend: ai_usage.Spend },
    note: []const u8,
};

const max_rows = ai_usage.max_windows + 1;

const Card = struct {
    name: []const u8,
    icon: ?w32.HICON,
    rows: [max_rows]Row = undefined,
    len: usize = 0,

    fn add(self: *Card, row: Row) void {
        if (self.len == max_rows) return;
        self.rows[self.len] = row;
        self.len += 1;
    }
};

/// The cards to show, in order. Rows point into `view.usage`.
fn cards(view: View, out: *[3]Card) []const Card {
    const text = profiles.data.sidebar.ai;
    const u = view.usage;
    var n: usize = 0;
    for ([_]struct { []const u8, *const ai_usage.Plan, ?w32.HICON }{
        .{ text.claude, &u.claude, view.icons[0] },
        .{ text.codex, &u.codex, view.icons[1] },
    }) |tool| {
        const name, const plan, const icon = tool;
        if (!plan.found) continue;
        var card: Card = .{ .name = name, .icon = icon };
        for (&plan.windows) |*slot| {
            if (slot.*) |*w| card.add(.{ .window = .{ .window = w } });
        }
        // Windows the user switched off leave nothing, not a note.
        if (card.len == 0 and !plan.hid_some) card.add(.{ .note = if (plan.answered) text.no_plan_limits else text.checking });
        if (card.len > 0) {
            out[n] = card;
            n += 1;
        }
    }
    if (u.opencode_found) {
        var card: Card = .{ .name = text.opencode, .icon = view.icons[2] };
        if (u.opencode_today) |s| card.add(.{ .spend = .{ .what = text.today, .spend = s } });
        if (u.opencode_week) |s| card.add(.{ .spend = .{ .what = text.this_week, .spend = s } });
        if (card.len > 0) {
            out[n] = card;
            n += 1;
        }
    }
    return out[0..n];
}

/// The section's height at `scale`; 0 when there is nothing to show.
pub fn height(view: View, scale: f32) i32 {
    return walk(view, scale, null, 0);
}

pub fn paint(c: Canvas, scale: f32, palette: tab_strip.Palette, fonts: tab_sidebar.Fonts, view: View, top: i32, spots: *tab_sidebar.Spots) void {
    _ = walk(view, scale, .{ .c = c, .palette = palette, .fonts = fonts, .spots = spots }, top);
}

/// Lay the section out from `top`, painting it when `p` is given, and
/// return its height. Measuring and painting share this one walk.
fn walk(view: View, scale: f32, p: ?Paint, top: i32) i32 {
    var buf: [3]Card = undefined;
    const shown = cards(view, &buf);
    if (shown.len == 0) return 0;
    const s = Scale{ .s = scale };
    var y = top;

    if (p) |pt| {
        pt.c.fill(.{ .left = 0, .top = top, .right = pt.c.width, .bottom = pt.c.height }, pt.palette.strip);
        paintTitle(pt, s, view, y);
    }
    y += s.px(title_height);
    if (!view.folded) {
        for (shown) |card| {
            const card_top = y;
            var inner = y + s.px(card_pad) + s.px(header_height);
            for (card.rows[0..card.len]) |row| inner += rowHeight(s, row) + s.px(row_gap);
            const card_bottom = inner - s.px(row_gap) + s.px(card_pad);
            if (p) |pt| paintCard(pt, s, view, card, card_top, card_bottom);
            y = card_bottom + s.px(card_gap);
        }
    }
    return y - top + s.px(pad - card_gap);
}

const Scale = struct {
    s: f32,
    fn px(self: Scale, value: f32) i32 {
        return @intFromFloat(@round(value * self.s));
    }
};

fn rowHeight(s: Scale, row: Row) i32 {
    return switch (row) {
        .window => s.px(line_height) + s.px(bar_gap) + s.px(bar_height) + s.px(bar_gap) + s.px(sub_height),
        .spend => s.px(line_height) + s.px(sub_height),
        .note => s.px(line_height),
    };
}

/// The title, drawn as the list's sections are, with an arrow that tells
/// folded from open.
fn paintTitle(p: Paint, s: Scale, view: View, y: i32) void {
    const c = p.c;
    const title = profiles.data.sidebar.ai.title;
    const h = s.px(title_height);
    const left = s.px(pad + 6);
    const right = c.width - s.px(pad + 6);
    const header: w32.RECT = .{ .left = s.px(pad), .top = y, .right = c.width - s.px(pad), .bottom = y + h };
    if (view.title_hovered) c.fillRounded(header, s.px(6), p.palette.hover);
    c.text(.{ .left = left, .top = y, .right = right, .bottom = y + h }, title, p.fonts.small, if (view.title_hovered) p.palette.text else p.palette.text_dim, .left);
    const arrow_w = s.px(icon_size);
    c.glyph(.{ .left = right - arrow_w, .top = y, .right = right, .bottom = y + h }, if (view.folded) chevron_right else chevron_down, p.fonts.icons_tiny, p.palette.text_dim);
    const rule_left = left + c.textWidth(title, p.fonts.small) + s.px(10);
    const rule_right = right - arrow_w - s.px(6);
    const mid = y + @divTrunc(h, 2);
    if (rule_right > rule_left) c.fill(.{ .left = rule_left, .top = mid, .right = rule_right, .bottom = mid + 1 }, p.palette.separator);
    p.spots.add(header, .usage_title);
}

fn paintCard(p: Paint, s: Scale, view: View, card: Card, top: i32, bottom: i32) void {
    const c = p.c;
    const pal = p.palette;
    const box: w32.RECT = .{ .left = s.px(pad), .top = top, .right = c.width - s.px(pad), .bottom = bottom };
    c.sync();
    c.fillRounded(box, s.px(card_corner), pal.strip.mix(pal.contrast, 0.05));
    const left = box.left + s.px(card_pad);
    const right = box.right - s.px(card_pad);
    var y = top + s.px(card_pad);

    // The tool's icon, or its initial where the program has none.
    const size = s.px(icon_size);
    const icon_top = y + @divTrunc(s.px(header_height) - size, 2);
    c.sync();
    if (card.icon) |icon| {
        _ = w32.DrawIconEx(c.hdc, left, icon_top, icon, size, size, 0, null, w32.DI_NORMAL);
    } else {
        const square: w32.RECT = .{ .left = left, .top = icon_top, .right = left + size, .bottom = icon_top + size };
        c.fillRounded(square, s.px(4), pal.strip.mix(pal.contrast, 0.16));
        c.text(square, card.name[0..1], p.fonts.small, pal.text, .center);
    }
    c.text(.{ .left = left + size + s.px(8), .top = y, .right = right, .bottom = y + s.px(header_height) }, card.name, p.fonts.item_strong, pal.text, .left);
    y += s.px(header_height);

    for (card.rows[0..card.len]) |row| {
        const line: w32.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + s.px(line_height) };
        switch (row) {
            .window => |r| {
                const w = r.window;
                var value_buf: [32]u8 = undefined;
                const left_pct = 100 - std.math.clamp(w.percent, 0, 100);
                const value = std.fmt.bufPrint(&value_buf, "{d}% {s}", .{ @as(u32, @intFromFloat(@round(left_pct))), profiles.data.sidebar.ai.left }) catch "";
                var label_buf: [64]u8 = undefined;
                paintLine(p, s, line, windowLabel(&label_buf, w), value);
                y += s.px(line_height) + s.px(bar_gap);

                // The bar empties as the window is used, and warns near the end.
                const bar_h = s.px(bar_height);
                const track: w32.RECT = .{ .left = left, .top = y, .right = right, .bottom = y + bar_h };
                c.sync();
                c.fillRounded(track, @divTrunc(bar_h, 2), pal.strip.mix(pal.contrast, 0.14));
                const fill_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(right - left)) * left_pct / 100));
                if (fill_w > 0) {
                    const ai = profiles.data.sidebar.ai;
                    const color: Rgb = if (w.percent >= @as(f32, @floatFromInt(ai.warn_percent)))
                        .{ .r = ai.warning_color.r, .g = ai.warning_color.g, .b = ai.warning_color.b }
                    else
                        pal.text.mix(pal.strip, 0.25);
                    c.fillRounded(.{ .left = left, .top = y, .right = left + @max(fill_w, bar_h), .bottom = y + bar_h }, @divTrunc(bar_h, 2), color);
                }
                y += bar_h + s.px(bar_gap);
                var reset_buf: [48]u8 = undefined;
                c.text(.{ .left = left, .top = y, .right = right, .bottom = y + s.px(sub_height) }, resetText(&reset_buf, w.resets_at, view.now_s), p.fonts.small, pal.text_dim, .left);
                y += s.px(sub_height);
            },
            .spend => |r| {
                var value_buf: [32]u8 = undefined;
                paintLine(p, s, line, r.what, std.fmt.bufPrint(&value_buf, "${d:.2}", .{r.spend.cost_usd}) catch "");
                y += s.px(line_height);
                var tokens_buf: [48]u8 = undefined;
                c.text(.{ .left = left, .top = y, .right = right, .bottom = y + s.px(sub_height) }, tokensText(&tokens_buf, r.spend.tokens), p.fonts.small, pal.text_dim, .left);
                y += s.px(sub_height);
            },
            .note => |note| {
                c.text(line, note, p.fonts.small, pal.text_dim, .left);
                y += s.px(line_height);
            },
        }
        y += s.px(row_gap);
    }
}

/// A label on the left and its figure, bold, on the right; a narrow
/// sidebar cuts the label, never the figure.
fn paintLine(p: Paint, s: Scale, line: w32.RECT, label: []const u8, value: []const u8) void {
    const value_w = p.c.textWidth(value, p.fonts.item_strong) + s.px(8);
    p.c.text(.{ .left = line.left, .top = line.top, .right = @max(line.left, line.right - value_w), .bottom = line.bottom }, label, p.fonts.small, p.palette.text_dim, .left);
    p.c.text(line, value, p.fonts.item_strong, p.palette.text, .right);
}

/// "5-hour limit", "Weekly limit", or "Weekly limit · Fable" for a
/// single model's.
fn windowLabel(buf: []u8, w: *const ai_usage.Window) []const u8 {
    const text = profiles.data.sidebar.ai;
    const name = switch (w.minutes) {
        5 * 60 => text.five_hours,
        7 * 24 * 60 => text.week,
        28 * 24 * 60...31 * 24 * 60 => text.month,
        else => text.other_window,
    };
    if (w.kind != .model) return name;
    return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ name, w.model() }) catch name;
}

/// "Resets in 1h 18m", "Resets in 1d 5h", or "Resets Nov 24" a week or
/// more away, in the user's time zone.
fn resetText(buf: []u8, resets_at: i64, now_s: i64) []const u8 {
    const text = profiles.data.sidebar.ai;
    if (resets_at == 0 or resets_at <= now_s) return "";
    const minutes: u64 = @intCast(@divFloor(resets_at - now_s + 59, 60));
    const days = minutes / (24 * 60);
    const hours = (minutes / 60) % 24;
    if (days >= 7) {
        if (localDate(resets_at)) |date| {
            return std.fmt.bufPrint(buf, "{s} {s} {d}", .{ text.resets_on, text.months[date.wMonth - 1], date.wDay }) catch "";
        }
    }
    return if (days > 0)
        std.fmt.bufPrint(buf, "{s} {d}d {d}h", .{ text.resets_in, days, hours }) catch ""
    else if (hours > 0)
        std.fmt.bufPrint(buf, "{s} {d}h {d}m", .{ text.resets_in, hours, minutes % 60 }) catch ""
    else
        std.fmt.bufPrint(buf, "{s} {d}m", .{ text.resets_in, minutes }) catch "";
}

fn localDate(unix_s: i64) ?w32.SYSTEMTIME {
    // FILETIME counts 100 ns steps from 1601.
    const ticks: u64 = @intCast((unix_s + 11_644_473_600) * 10_000_000);
    const file: w32.FILETIME = .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
    var utc: w32.SYSTEMTIME = undefined;
    var local: w32.SYSTEMTIME = undefined;
    if (w32.FileTimeToSystemTime(&file, &utc) == 0) return null;
    if (w32.SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return null;
    if (local.wMonth < 1 or local.wMonth > 12) return null;
    return local;
}

/// "248k tokens" or "1.4M tokens".
fn tokensText(buf: []u8, tokens: u64) []const u8 {
    const word = profiles.data.sidebar.ai.tokens;
    return if (tokens >= 1_000_000)
        std.fmt.bufPrint(buf, "{d:.1}M {s}", .{ @as(f64, @floatFromInt(tokens)) / 1_000_000, word }) catch ""
    else
        std.fmt.bufPrint(buf, "{d}k {s}", .{ tokens / 1000, word }) catch "";
}
