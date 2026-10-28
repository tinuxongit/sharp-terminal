//! Consoles Windows hands to Sharp as its default terminal, from the moment
//! one arrives (apprt/win32/terminal_handoff.zig, on a COM thread) until
//! its tab's IO thread takes it (termio/Exec.zig). A tab asks for its
//! console through its command, `sharp-handoff:<id>`, which names no
//! program, so a tab can only ever get the console made for it.
const std = @import("std");
const windows = @import("windows.zig");
const console_programs = @import("console_programs.zig");
const Pty = @import("../pty.zig").Pty;

const kernel32 = windows.exp.kernel32;
const log = std.log.scoped(.console_handoff);

/// A handed-over console, as its tab runs it.
pub const Console = struct {
    pty: Pty,
    /// The program the console was made for, opened so the tab can end it
    /// and see it exit, like a shell it started.
    client: windows.HANDLE,
    /// Its job (console_programs.zig), so what it launches ends with the
    /// tab; null if Windows refused one.
    job: ?windows.HANDLE,
};

/// What the console host gets back: the console's ends of the pipes,
/// which it owns from then on, and the id its tab asks for.
pub const Arrival = struct {
    id: u32,
    input: windows.HANDLE,
    output: windows.HANDLE,
};

const prefix = "sharp-handoff:";

/// Consoles waiting for their tab; a tab opens within moments, so a few
/// cover a burst of programs started together.
var waiting: [8]?struct { id: u32, console: Console } = @splat(null);
var next_id: u32 = 1;
var busy = std.atomic.Value(bool).init(false);

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    busy.store(false, .release);
}

/// Take over the console a host hands over. Its handles stay the
/// caller's: the console keeps copies.
pub fn arrive(
    server: windows.HANDLE,
    reference: windows.HANDLE,
    signal: windows.HANDLE,
    client: windows.HANDLE,
) !Arrival {
    const own_server = try duplicate(server);
    const own_reference = duplicate(reference) catch |err| {
        _ = kernel32.CloseHandle(own_server);
        return err;
    };
    const own_signal = duplicate(signal) catch |err| {
        _ = kernel32.CloseHandle(own_server);
        _ = kernel32.CloseHandle(own_reference);
        return err;
    };
    var pty = Pty.adopt(.{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 }, own_server, own_reference, own_signal) catch |err| {
        _ = kernel32.CloseHandle(own_server);
        _ = kernel32.CloseHandle(own_reference);
        _ = kernel32.CloseHandle(own_signal);
        return err;
    };
    errdefer pty.deinit();

    // The host's handle can't end the program or put it in a job; asking
    // Windows again by its id can, as the same user.
    const pid = kernel32.GetProcessId(client);
    const rights = windows.PROCESS_TERMINATE | windows.PROCESS_SET_QUOTA | windows.PROCESS_QUERY_LIMITED_INFORMATION | windows.SYNCHRONIZE;
    const program = kernel32.OpenProcess(rights, windows.FALSE, pid) orelse try duplicate(client);
    errdefer _ = kernel32.CloseHandle(program);
    const job = console_programs.createJob();
    if (job) |j| {
        if (kernel32.AssignProcessToJobObject(j, program) == windows.FALSE) {
            log.warn("could not put the handed-over program in a job err={}", .{windows.GetLastError()});
        } else console_programs.register(j, pid);
    }
    errdefer if (job) |j| {
        console_programs.unregister(j);
        _ = kernel32.CloseHandle(j);
    };

    const input = try duplicate(pty.in_pipe_pty);
    errdefer _ = kernel32.CloseHandle(input);
    const output = try duplicate(pty.out_pipe_pty);
    errdefer _ = kernel32.CloseHandle(output);

    lock();
    defer unlock();
    for (&waiting) |*slot| {
        if (slot.* != null) continue;
        const id = next_id;
        next_id +%= 1;
        slot.* = .{ .id = id, .console = .{ .pty = pty, .client = program, .job = job } };
        return .{ .id = id, .input = input, .output = output };
    }
    return error.TooManyConsoles;
}

/// The command of the tab that runs console `id`.
pub fn command(id: u32, buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, prefix ++ "{d}", .{id}, 0) catch null;
}

/// The console a tab's command asks for, which the tab then owns; null
/// for every other command.
pub fn take(args: []const [:0]const u8) ?Console {
    if (args.len != 1 or !std.mem.startsWith(u8, args[0], prefix)) return null;
    const id = std.fmt.parseInt(u32, args[0][prefix.len..], 10) catch return null;
    lock();
    defer unlock();
    for (&waiting) |*slot| {
        const entry = slot.* orelse continue;
        if (entry.id != id) continue;
        slot.* = null;
        return entry.console;
    }
    return null;
}

/// Let go of a console whose tab couldn't open; its program ends.
pub fn discard(id: u32) void {
    var buf: [32]u8 = undefined;
    const name = command(id, &buf) orelse return;
    var console = take(&.{name}) orelse return;
    if (console.job) |job| {
        console_programs.end(job, kernel32.GetProcessId(console.client));
        console_programs.unregister(job);
        _ = kernel32.CloseHandle(job);
    }
    _ = kernel32.TerminateProcess(console.client, 1);
    _ = kernel32.CloseHandle(console.client);
    console.pty.deinit();
}

fn duplicate(handle: windows.HANDLE) !windows.HANDLE {
    const self = kernel32.GetCurrentProcess();
    var copy: windows.HANDLE = undefined;
    if (kernel32.DuplicateHandle(self, handle, self, &copy, 0, windows.FALSE, windows.DUPLICATE_SAME_ACCESS) == windows.FALSE)
        return windows.unexpectedError(windows.GetLastError());
    return copy;
}
