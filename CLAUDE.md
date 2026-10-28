# Sharp

Sharp is a native Windows terminal emulator. It is a fork of
[shiweis/ghostty-windows](https://github.com/shiweis/ghostty-windows), which is
itself a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a
Win32 app runtime. All three are MIT licensed. `AGENTS.md` has the upstream
commands and conventions; this file covers what is specific to Sharp.

## Remotes

- `upstream`: ghostty-org/ghostty. The shared terminal core comes from here.
- `winfork`: shiweis/ghostty-windows. The Win32 runtime comes from here.
- No `origin` yet. The repo is local only until we decide to publish it.

## Who owns what

- `src/apprt/win32/`: the Windows app (windows, tabs, splits, input, IME,
  clipboard, quick terminal). `win32.zig` holds the raw Win32 API bindings.
- `src/apprt/win32/UntrustedUrl.zig`: decides which links printed by programs
  may be opened. Anything that reaches `ShellExecuteW` from terminal output
  must go through it.
- `src/os/Conpty.zig` and `pkg/conpty/`: the bundled Microsoft ConPTY. The
  package is pinned by version and SHA-256 in `pkg/conpty/fetch.zig`.
- `src/font/directwrite.zig`: finds system fonts on Windows.
- `dist/windows/`: icon, resource file and packaging scripts.
- Everything else in `src/` is the shared Ghostty core. Keep changes there
  small so upstream merges stay easy.

## Build

Zig 0.17.0 lives in `C:\dev\tools\zig-x86_64-windows-0.17.0\`.

```
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast
```

## Key decisions

- **Built on the existing Windows fork, not from scratch.** We reviewed it on
  2026-10-28: the ConPTY download is pinned and hash-checked, the DLL loads
  only from the app folder, links from terminal output are filtered, and
  clipboard reads by programs ask first. Its code follows upstream style.
- **Win32 + OpenGL (WGL), not WinUI or DirectX.** It reuses Ghostty's OpenGL
  renderer, so there is no second renderer to maintain.

## Performance budget

Load: dump a 50 MB text file to the terminal, then scroll up and down through
the scrollback.

- Average frame: 4 ms or less.
- Worst frame: 16 ms or less.

## Tech debt

- The update checker in `src/apprt/win32/App.zig` contacts the original fork's
  GitHub releases every hour by default. Sharp should turn it off or point it
  at its own releases.
- The window still says "Ghostty" everywhere: title, exe name, icon, config
  folder, taskbar ID. The rename to Sharp is not done yet.
- `App.zig`, `Surface.zig` and `Window.zig` in the Win32 runtime are each
  2,600 to 3,400 lines and mix several jobs. Upstream's GTK files are just as
  large, so splitting them makes merges from `winfork` harder.
- The frame-time benchmark for the budget above does not exist yet.
- The fork removed upstream's CI workflows and contributor docs (`HACKING.md`,
  `CONTRIBUTING.md`).
