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
- `src/apprt/win32/wide_string.zig`: the one place that converts text into
  fixed-size UTF-16 buffers. `std.unicode.utf8ToUtf16Le` does not
  bounds-check, so never call it on a fixed buffer with text whose length
  you have not checked first.
- `src/apprt/win32/brand.zig`: the name shown in titles, dialogs and the
  tray, and the prefix of the Win32 window classes.
- `src/apprt/win32/tab_strip.zig`: the strip at the top of a window (tabs,
  new-tab and settings buttons, minimize/maximize/close), with its layout,
  hit-testing, colors and painting. `Window.zig` only feeds it state and turns its
  hit-test results into window messages (`WM_NCCALCSIZE`, `WM_NCHITTEST`).
- `src/apprt/win32/settings.zon`: everything the settings panel offers
  (categories, settings, descriptions, choices) and its text. Add or change
  settings here, not in code.
- `src/apprt/win32/settings.zig`: reads that data and relates each setting
  to the config file (current value, toggles, search, dropdown choices).
- `src/apprt/win32/settings_view.zig`: lays out and paints the panel.
- `src/apprt/win32/SettingsPanel.zig`: the panel's layered window, input,
  and state.
- `src/apprt/win32/canvas.zig`: drawing shared by the strip and the panel
  (colors, anti-aliased shapes, text, icon fonts).
- `src/apprt/win32/menu_theme.zig`: dark or light native popup menus.
- `src/apprt/win32/config_file.zig`: reads and changes one key of the
  user's Ghostty config file, leaving the rest of it untouched.
- `src/font/directwrite.zig`: finds system fonts on Windows.
- `dist/windows/`: icon, resource file and packaging scripts.
- Everything else in `src/` is the shared Ghostty core. Keep changes there
  small so upstream merges stay easy.

## Build

Zig 0.17.0 lives in `C:\dev\tools\zig-x86_64-windows-0.17.0\`. The GNU
target is required: the default MSVC target fails in translate-c. The
output goes to `zig-out\bin\sharp.exe`, next to the Microsoft-signed
`conpty.dll` and `OpenConsole.exe`.

```
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

## Key decisions

- **Built on the existing Windows fork, not from scratch.** A deep review on
  2026-10-28 found the design sound: the ConPTY download is pinned and
  hash-checked, the DLL loads only from the app folder, links from terminal
  output are filtered, and clipboard reads by programs ask first. Much of the
  fork is AI-written, and its careful comments hide real bugs. It wrote tab
  titles, notifications and search text into fixed buffers without bounds
  checks, so any program could overflow the stack with a long title. Those
  are fixed. Review fork code before trusting it, and especially code
  that handles terminal output.
- **Win32 + OpenGL (WGL), not WinUI or DirectX.** It reuses Ghostty's OpenGL
  renderer, so there is no second renderer to maintain.
- **Tabs live in the title bar, as in Windows Terminal.** The Windows caption
  is removed and the tab strip draws its own caption buttons. Its colors are
  derived from the terminal's background and foreground, so every theme
  matches. Rounded corners are anti-aliased by hand rather than pulling in
  GDI+. Not yet tried on Windows 10.
- **Tabs behave like Chrome's.** Equal widths up to 240 px that shrink as
  tabs open, titles that fade instead of an ellipsis, a close button on
  inactive tabs only when there is room (Chromium's 68 px content rule),
  middle-click to close, and closing with the mouse keeps the other tabs'
  width until the pointer leaves them. Numbers come from Chromium's
  `tab_style.cc` and `tab.cc`.
- **Closing asks only when a command is running.** Shells with prompt
  marks (PowerShell with Sharp's integration) answer through the prompt
  test. `cmd.exe` sends none, so on Windows a command counts as running
  when the shell has a child process (`Subprocess.commandRunning`).
- **Settings are a panel that writes the config file.** The gear, beside
  minimize, opens a panel over the dimmed terminal, laid out like T3
  Code's: searchable categories on the left, cards of settings with
  dropdowns and switches on the right. A change writes `key = value` to
  Ghostty's config file and reloads it, so the file stays the single
  source of truth. The panel is a per-pixel-alpha layered window drawn
  with `canvas.zig`, so it has no child controls; the search box is drawn
  too, and typing anywhere in the panel searches. Dropdowns open native
  menus, themed through uxtheme's unnamed SetPreferredAppMode export, as
  Explorer and Notepad do.
- **Images use the kitty graphics protocol.** The bundled ConPTY passes it
  through (checked 2026-10-28 with OpenConsole 1.25; the inbox Windows
  ConPTY strips it). `chafa` picks it automatically via `TERM_PROGRAM`.
  Ghostty has no Sixel support.
- **Sharp to people, Ghostty to programs.** The exe, window text, dialogs and
  version info say Sharp. `TERM_PROGRAM`, terminfo, `GHOSTTY_*` variables,
  `share\ghostty` resources and the `%LOCALAPPDATA%\ghostty` config folder
  stay as they are, so programs keep their Ghostty support and Ghostty's
  themes and docs still apply. Only the Windows exe is renamed, which keeps
  merges from upstream simple.

## Performance budget

Load: dump a 50 MB text file to the terminal, then scroll up and down through
the scrollback.

- Average frame: 4 ms or less.
- Worst frame: 16 ms or less.

## Tech debt

- The update checker in `src/apprt/win32/App.zig` still points at the
  original fork's releases. It now runs only when `auto-update` is set.
  Point it at Sharp's releases once they exist, or delete it.
- The fork made renderer messages in the shared `src/Surface.zig` give up
  after 1 second, to survive a renderer that hangs in `SwapBuffers` after
  sleep. That hides the hang instead of fixing it, and a dropped config change
  leaves the renderer and terminal with different settings.
- Closing a tab kills only the shell (`TerminateProcess`). There is no Job
  Object, so programs started from it in the background can keep running.
- The PowerShell integration script reports the working directory in OSC 7
  without percent-encoding, so folders containing `%` or `#` are misread.
- The fork deleted upstream's `test.yml` CI, so upstream's core tests no
  longer run on its changes to shared files.
- Leftover debug log lines in `Surface.init` (`"renderer created"` and so on).
- The icon (`dist/windows/ghostty.ico`) is still Ghostty's ghost, and the
  version info still says 1.3.0.0, inherited from the fork.
- `App.zig`, `Surface.zig` and `Window.zig` in the Win32 runtime are each
  2,600 to 3,400 lines and mix several jobs. Upstream's GTK files are just as
  large, so splitting them makes merges from `winfork` harder.
- The frame-time benchmark for the budget above does not exist yet.
- Replies to programs that probe for image support travel back through
  ConPTY's input side, which reportedly drops APC replies. Tools that
  insist on a reply may not detect image support. Unverified.
- `commandRunning` matches children by parent PID, which Windows reuses, so
  an unrelated process could rarely look like a running command.
- The fork removed upstream's CI workflows and contributor docs (`HACKING.md`,
  `CONTRIBUTING.md`).
