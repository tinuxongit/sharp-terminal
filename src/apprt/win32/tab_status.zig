//! What a tab shows of the state its programs report through OSC 7501,
//! as Claude Code reports working, waiting on the user, or done. Programs
//! that report it leave the status glyph out of their title, so the strip
//! and the sidebar draw it instead.

const w32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const apprt = @import("../../apprt.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const Surface = @import("Surface.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = canvas_mod.Rgb;

pub const Status = apprt.action.ProgramStatus;

// Colors that stand out on any theme, like the update button's green.
const done_green: Rgb = .{ .r = 0x3F, .g = 0xB9, .b = 0x50 };
const blocked_amber: Rgb = .{ .r = 0xE8, .g = 0xA3, .b = 0x17 };
const error_red: Rgb = .{ .r = 0xE5, .g = 0x48, .b = 0x3E };

/// The state of the tab's most urgent pane: one that waits on the user
/// matters more than one that finished, which matters more than one at
/// work.
pub fn ofTab(tree: *const SplitTree(Surface)) Status {
    var result: Status = .idle;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const status = shown(entry.view);
        if (urgency(status) > urgency(result)) result = status;
    }
    return result;
}

/// Work that finished or failed while the user watched, or that they have
/// looked at since, needs no mark. Working and waiting stay shown.
fn shown(pane: *const Surface) Status {
    return switch (pane.program_status) {
        .done, .@"error" => if (pane.status_seen) .idle else pane.program_status,
        else => pane.program_status,
    };
}

fn urgency(status: Status) u8 {
    return switch (status) {
        .idle => 0,
        .working => 1,
        .done => 2,
        .@"error" => 3,
        .blocked => 4,
    };
}

/// Draw the mark for `status`, a dot `size` wide centered in `rect`:
/// a ring while working, filled once the user should look. `ring` is the
/// working ring's color and `background` what lies under the mark. Idle
/// draws nothing.
pub fn paint(c: Canvas, rect: w32.RECT, status: Status, size: i32, ring: Rgb, background: Rgb) void {
    const color: Rgb = switch (status) {
        .idle => return,
        .working => ring,
        .done => done_green,
        .blocked => blocked_amber,
        .@"error" => error_red,
    };
    const left = rect.left + @divTrunc(rect.right - rect.left - size, 2);
    const top = rect.top + @divTrunc(rect.bottom - rect.top - size, 2);
    const dot: w32.RECT = .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
    c.fillRounded(dot, @divTrunc(size, 2), color);
    if (status == .working) {
        const stroke = @max(1, @divTrunc(size, 4));
        const hole: w32.RECT = .{ .left = dot.left + stroke, .top = dot.top + stroke, .right = dot.right - stroke, .bottom = dot.bottom - stroke };
        c.fillRounded(hole, @divTrunc(size - 2 * stroke, 2), background);
    }
}
