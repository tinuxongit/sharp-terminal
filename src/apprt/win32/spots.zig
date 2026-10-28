//! Clickable regions recorded while painting Sharp's own UI, so input
//! hit-tests exactly what was drawn.
const w32 = @import("win32.zig");

pub fn Spots(comptime Target: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]Spot = undefined,
        len: usize = 0,

        pub const Spot = struct { rect: w32.RECT, target: Target };

        pub fn add(self: *Self, rect: w32.RECT, target: Target) void {
            if (self.len == self.items.len) return;
            self.items[self.len] = .{ .rect = rect, .target = target };
            self.len += 1;
        }

        /// The topmost spot under a point: later spots were drawn on top.
        pub fn at(self: *const Self, x: i32, y: i32) ?Spot {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                const r = self.items[i].rect;
                if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return self.items[i];
            }
            return null;
        }
    };
}
