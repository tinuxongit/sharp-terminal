//! Keeps a surface's renderer to one frame per display refresh. SwapBuffers
//! no longer waits for the display (see Surface.disableSwapWait), since
//! that wait could block forever with the display off after sleep, so
//! without this the renderer would draw hundreds of unseen frames a second
//! while output streams in. The wait here is bounded by one refresh, and
//! a frame after a pause is never delayed.
const FramePacer = @This();

const std = @import("std");
const w32 = @import("win32.zig");

/// When the last paced frame finished, from QueryPerformanceCounter.
last: i64 = 0,
/// A high-resolution waitable timer, made on the renderer thread when
/// first needed; plain Sleep rounds to the 15.6 ms system tick.
timer: ?w32.HANDLE = null,

pub fn deinit(self: *FramePacer) void {
    if (self.timer) |t| _ = w32.CloseHandle(t);
    self.timer = null;
}

/// Wait out the rest of the display's refresh interval since the last
/// frame. Called on the renderer thread after each frame.
pub fn frameDone(self: *FramePacer, hdc: ?w32.HDC) void {
    var freq: i64 = 0;
    var now: i64 = 0;
    _ = w32.QueryPerformanceFrequency(&freq);
    _ = w32.QueryPerformanceCounter(&now);
    if (freq <= 0) return;
    const hz = refreshRate(hdc);
    const interval = @divTrunc(freq, hz);
    const due = self.last + interval;
    if (self.last != 0 and now < due) {
        // Negative due times are relative, in 100 ns units.
        const wait_100ns = @divTrunc((due - now) * 10_000_000, freq);
        if (self.timerHandle()) |t| {
            const relative: i64 = -wait_100ns;
            if (w32.SetWaitableTimer(t, &relative, 0, null, null, 0) != 0) {
                _ = w32.WaitForSingleObject(t, w32.INFINITE);
            }
        }
        self.last = due;
    } else {
        self.last = now;
    }
}

/// The display's refresh rate in Hz, clamped to what monitors really use.
fn refreshRate(hdc: ?w32.HDC) i64 {
    const dc = hdc orelse return 60;
    const hz = w32.GetDeviceCaps(dc, w32.VREFRESH);
    // 0 and 1 mean "the hardware's default".
    return if (hz < 24 or hz > 500) 60 else hz;
}

fn timerHandle(self: *FramePacer) ?w32.HANDLE {
    if (self.timer == null) {
        self.timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS);
    }
    return self.timer;
}
