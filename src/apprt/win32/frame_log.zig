//! Frame times for the performance budget's benchmark
//! (`dist/windows/frame_benchmark.py`). With SHARP_FRAME_LOG set to a file
//! path, every frame a renderer builds is written there as one line,
//! "<total_us> <swap_us>": the time spent updating and drawing it, and the
//! part of that spent in SwapBuffers, which waits for the display rather
//! than working. Off, and free, unless the variable is set.
const std = @import("std");
const global = @import("../../global.zig");

/// Each tab renders on its own thread, so lines are written under a lock.
var mutex: std.Io.Mutex = .init;
var state: enum { unknown, off, on } = .unknown;
var file: std.Io.File = undefined;

pub fn record(total_ns: u64, swap_ns: u64) void {
    const io = global.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (state == .unknown) state = open();
    if (state == .off) return;
    var line: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d} {d}\n", .{ total_ns / 1000, swap_ns / 1000 }) catch return;
    file.writeStreamingAll(io, text) catch {
        state = .off;
    };
}

fn open() @TypeOf(state) {
    const alloc = std.heap.page_allocator;
    const path = global.environ().getAlloc(alloc, "SHARP_FRAME_LOG") catch return .off;
    defer alloc.free(path);
    file = std.Io.Dir.cwd().createFile(global.io(), path, .{}) catch return .off;
    return .on;
}
