//! Frame times for the performance budget's benchmark
//! (`dist/windows/frame_benchmark.py`). With SHARP_FRAME_LOG set to a file
//! path, every frame a renderer builds is written there as one line,
//! "<total_us> <swap_us>": the time spent updating and drawing it, and the
//! part of that spent in SwapBuffers, which waits for the display rather
//! than working. Off, and free, unless the variable is set.
const std = @import("std");
const global = @import("../../global.zig");

const State = enum(u8) { unknown, off, on };

/// Each tab renders on its own thread, so lines are written under a lock.
/// The state is read without it first, so frames cost nothing while off.
var mutex: std.Io.Mutex = .init;
var state: std.atomic.Value(State) = .init(.unknown);
var file: std.Io.File = undefined;

pub fn record(total_ns: u64, swap_ns: u64) void {
    if (state.load(.acquire) == .off) return;
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (state.load(.acquire) == .unknown) state.store(open(), .release);
    if (state.load(.acquire) == .off) return;
    var line: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d} {d}\n", .{ total_ns / 1000, swap_ns / 1000 }) catch return;
    file.writeStreamingAll(io, text) catch state.store(.off, .release);
}

fn open() State {
    const alloc = std.heap.page_allocator;
    const path = global.environ().getAlloc(alloc, "SHARP_FRAME_LOG") catch return .off;
    defer alloc.free(path);
    file = std.Io.Dir.cwd().createFile(global.io(), path, .{}) catch return .off;
    return .on;
}
