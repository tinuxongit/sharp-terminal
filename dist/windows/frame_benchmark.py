"""Measure Sharp's frame times against the performance budget in CLAUDE.md:
dump a 50 MB text file to the terminal, then scroll up and down through the
scrollback, and report the average and worst frame.

usage: python frame_benchmark.py <path to sharp.exe> [label]
           [--baseline <json>] [--save-baseline <json>]

With --baseline the run fails (exit code 1) when it breaks the budget or
its average frame is more than 30 % slower than the saved baseline's,
which --save-baseline records. The post-commit hook runs it this way
(dist/windows/hooks/post-commit).

Sharp writes one line per frame to the file named by SHARP_FRAME_LOG
(src/apprt/win32/frame_log.zig): the frame's total time and the part spent
in SwapBuffers waiting for the display. "Work" is the total minus that
wait, which is what the budget limits.

The window opens on the second monitor when there is one, and is driven
only by posted messages: it never takes focus or moves the mouse. Sharp
runs with default settings (`--config-default-files=false`), so the
user's config and saved session are neither used nor changed.
"""
import ctypes, ctypes.wintypes as wt, json, os, random, subprocess, sys, tempfile, time

BUDGET_AVG_MS = 4.0
BUDGET_WORST_MS = 16.0
# Runs vary by about 10 %; a slowdown past this is a regression.
REGRESSION_LIMIT = 1.30
DUMP_BYTES = 50 * 1024 * 1024
SCROLL_STEPS = 600       # wheel messages each way
SCROLL_NOTCHES = 10      # notches per message
SCROLL_INTERVAL = 0.016  # one message per display frame
QUIET_SETTLE = 2.0       # seconds of few frames that mean the dump is done

u32 = ctypes.WinDLL("user32")
u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
u32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]

WM_CLOSE, WM_KEYDOWN, WM_KEYUP, WM_CHAR, WM_MOUSEWHEEL = 0x10, 0x100, 0x101, 0x102, 0x20A


def sample_file():
    """The 50 MB dump, made once and kept in the temp folder."""
    path = os.path.join(tempfile.gettempdir(), "sharp-benchmark-50mb.txt")
    if os.path.exists(path) and os.path.getsize(path) >= DUMP_BYTES:
        return path
    rng = random.Random(1)
    words = ["terminal", "render", "frame", "glyph", "buffer", "scroll", "cursor", "shell",
             "font", "atlas", "cell", "row", "column", "ansi", "unicode", "pty", "draw",
             "{", "}", "=>", "0x7fff", "error:", "warning:", "src/main.zig:42:13", "|", "--"]
    with open(path, "w", encoding="utf-8", newline="\r\n") as f:
        written = 0
        while written < DUMP_BYTES:
            line = " ".join(rng.choice(words) for _ in range(rng.randint(0, 22)))
            f.write(line + "\n")
            written += len(line) + 2
    return path


def monitor_work_area():
    """The second monitor's work area, else the primary's."""
    class MI(ctypes.Structure):
        _fields_ = [("cbSize", wt.DWORD), ("rcMonitor", wt.RECT), ("rcWork", wt.RECT), ("dwFlags", wt.DWORD)]
    areas = []
    P = ctypes.WINFUNCTYPE(wt.BOOL, wt.HMONITOR, wt.HDC, ctypes.POINTER(wt.RECT), wt.LPARAM)
    def cb(m, d, r, l):
        mi = MI(); mi.cbSize = ctypes.sizeof(MI); u32.GetMonitorInfoW(m, ctypes.byref(mi))
        areas.append((mi.dwFlags & 1, mi.rcWork))
        return True
    u32.EnumDisplayMonitors(None, None, P(cb), 0)
    areas.sort(key=lambda a: a[0])  # non-primary first
    return areas[0][1]


def windows_of(pid, cls):
    found = []
    P = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, l):
        owner = wt.DWORD(); u32.GetWindowThreadProcessId(h, ctypes.byref(owner))
        name = ctypes.create_unicode_buffer(64); u32.GetClassNameW(h, name, 64)
        if owner.value == pid and name.value == cls and u32.IsWindowVisible(h): found.append(h)
        return True
    u32.EnumWindows(P(cb), 0)
    return found


def terminal_of(top):
    found = []
    P = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, l):
        name = ctypes.create_unicode_buffer(64); u32.GetClassNameW(h, name, 64)
        if name.value == "SharpTerminal" and u32.IsWindowVisible(h): found.append(h)
        return True
    u32.EnumChildWindows(top, P(cb), 0)
    return found[0]


def type_text(hwnd, text):
    for ch in text:
        u32.PostMessageW(hwnd, WM_CHAR, ord(ch), 1)
    u32.PostMessageW(hwnd, WM_KEYDOWN, 0x0D, 1)
    u32.PostMessageW(hwnd, WM_KEYUP, 0x0D, 0xC0000001)


def frame_count(log):
    try:
        with open(log, encoding="ascii") as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def wait_until_quiet(log, quiet_rate=8, settle=QUIET_SETTLE, timeout=900):
    """Wait for the dump to finish: frames slow to the cursor's blink."""
    start = time.time()
    last, quiet_since = frame_count(log), None
    while time.time() - start < timeout:
        time.sleep(0.5)
        now = frame_count(log)
        if (now - last) * 2 <= quiet_rate:
            quiet_since = quiet_since or time.time()
            if time.time() - quiet_since >= settle:
                return
        else:
            quiet_since = None
        last = now
    sys.exit("the dump did not finish in time")


def scroll(hwnd, direction):
    r = wt.RECT(); u32.GetWindowRect(hwnd, ctypes.byref(r))
    lparam = (((r.top + 100) & 0xFFFF) << 16) | ((r.left + 100) & 0xFFFF)
    delta = (direction * 120 * SCROLL_NOTCHES) & 0xFFFF
    for _ in range(SCROLL_STEPS):
        u32.PostMessageW(hwnd, WM_MOUSEWHEEL, delta << 16, lparam)
        time.sleep(SCROLL_INTERVAL)


def stats(rows):
    totals = sorted(t for t, _ in rows)
    work = sorted(t - s for t, s in rows)
    def summary(values):
        return (sum(values) / len(values) / 1000, values[int(len(values) * 0.99) - 1] / 1000, values[-1] / 1000)
    return len(rows), summary(work), summary(totals)


def main():
    args = sys.argv[1:]
    def option(name):
        if name not in args:
            return None
        i = args.index(name)
        value = args[i + 1]
        del args[i:i + 2]
        return value
    baseline_path = option("--baseline")
    save_path = option("--save-baseline")
    exe = os.path.abspath(args[0])
    label = args[1] if len(args) > 1 else os.path.basename(os.path.dirname(os.path.dirname(exe)))
    dump = sample_file()
    log = os.path.join(tempfile.gettempdir(), f"sharp-frames-{os.getpid()}.log")
    env = dict(os.environ, SHARP_FRAME_LOG=log)

    si = subprocess.STARTUPINFO()
    si.dwFlags = subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 4  # SW_SHOWNOACTIVATE
    proc = subprocess.Popen([exe, "--config-default-files=false", "--confirm-close-surface=false"],
                            cwd=os.path.dirname(exe), env=env, startupinfo=si)
    try:
        top = None
        for _ in range(200):
            found = windows_of(proc.pid, "SharpWindow")
            if found:
                top = found[0]
                break
            time.sleep(0.05)
        if not top:
            sys.exit("Sharp's window did not appear")
        area = monitor_work_area()
        u32.SetWindowPos(top, None, area.left + 40, area.top + 40, 1600, 900, 0x4 | 0x10)  # NOZORDER | NOACTIVATE
        time.sleep(3)
        term = terminal_of(top)

        marks = [frame_count(log)]
        dump_start = time.time()
        type_text(term, f'type "{dump}"')
        wait_until_quiet(log)
        # wait_until_quiet waits for a quiet stretch after the dump ends.
        dump_seconds = time.time() - dump_start - QUIET_SETTLE
        marks.append(frame_count(log))
        scroll(term, +1)
        scroll(term, -1)
        time.sleep(1.5)
        marks.append(frame_count(log))
    finally:
        if proc.poll() is None:
            for h in windows_of(proc.pid, "SharpWindow"):
                u32.PostMessageW(h, WM_CLOSE, 0, 0)
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()

    with open(log, encoding="ascii") as f:
        rows = [tuple(int(v) for v in line.split()) for line in f if line.strip()]
    os.remove(log)
    print(f"{label}: {len(rows)} frames; the 50 MB dump took about {dump_seconds:.0f} s")
    print(f"{'phase':8} {'frames':>7}   {'work avg':>9} {'p99':>7} {'worst':>7}   {'with vsync wait avg':>20} {'worst':>7}")
    for name, a, b in (("dump", marks[0], marks[1]), ("scroll", marks[1], marks[2]), ("all", marks[0], marks[2])):
        part = rows[a:b]
        if not part:
            continue
        n, (wa, wp, ww), (ta, tp, tw) = stats(part)
        print(f"{name:8} {n:7}   {wa:7.2f}ms {wp:5.2f}ms {ww:5.2f}ms   {ta:18.2f}ms {tw:5.2f}ms")
    n, (wa, _, ww), _ = stats(rows[marks[0]:marks[2]])
    ok = wa <= BUDGET_AVG_MS and ww <= BUDGET_WORST_MS
    print(f"budget {BUDGET_AVG_MS} ms avg / {BUDGET_WORST_MS} ms worst: {'met' if ok else 'BROKEN'}")
    result = {"avg_ms": round(wa, 3), "worst_ms": round(ww, 3), "dump_seconds": round(dump_seconds, 1)}
    if save_path:
        with open(save_path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
        print(f"baseline saved to {save_path}")
    if baseline_path:
        with open(baseline_path, encoding="utf-8") as f:
            base = json.load(f)
        slower = wa / base["avg_ms"]
        regressed = slower > REGRESSION_LIMIT
        print(f"against the baseline ({base['avg_ms']} ms avg): {slower:.2f}x{' - REGRESSION' if regressed else ''}")
        if regressed or not ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
