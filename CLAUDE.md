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
- `src/os/console_programs.zig`: which programs a tab started on Windows
  (through its Job Object) and which of them end with it.
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
- `src/apprt/win32/frame_pacer.zig`: one frame per display refresh for each
  renderer thread.
- `src/apprt/win32/canvas.zig`: drawing shared by the strip and the panel
  (colors, anti-aliased shapes, text, icon fonts).
- `src/apprt/win32/menu_theme.zig`: dark or light native popup menus.
- `src/apprt/win32/profiles.zon`: the shell profiles (PowerShell, Command
  Prompt, Git Bash, Visual Studio prompts, WSL distributions) and the
  new-tab menu's text. Add shells here, not in code.
- `src/apprt/win32/profiles.zig`: resolves those against what is
  installed, and caches program icons.
- `src/apprt/win32/new_tab_menu.zig`: the menu behind the arrow beside
  "+", with icons and shortcuts.
- `src/apprt/win32/tab_sidebar.zig`: tabs as a list beside the terminal,
  grouped by where the shell runs and by folder; layout and painting.
- `src/apprt/win32/session.zig`: saves and loads the sidebar layout's
  open tabs (`sharp-session`, beside the config file).
- `src/apprt/win32/ssh.zig`: finds the server a tab's ssh is connected to.
- `src/apprt/win32/servers.zig`: the servers the sidebar offers (hosts in
  `~/.ssh/config` and recent ones), and which addresses ssh may be given.
- `src/apprt/win32/folder_picker.zig`: Windows' folder picker, behind the
  buttons on a sidebar section's title.
- `src/termio/cmd_prompt.zig`: makes cmd.exe report its folder (OSC 7)
  through its PROMPT.
- `src/apprt/win32/SearchField.zig`: the search box shared by the settings
  panel and the tab sidebar.
- `src/apprt/win32/spots.zig`: clickable regions recorded while painting.
- `src/apprt/win32/config_file.zig`: reads and changes one key of the
  user's Ghostty config file, leaving the rest of it untouched.
- `src/font/directwrite.zig`: finds system fonts on Windows.
- `dist/windows/`: icon, resource file and packaging scripts. `sharp.ico`
  is drawn by `make_logo.py` (Pillow): `python make_logo.py sharp.ico
  preview.png` regenerates it.
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
- **SwapBuffers never waits for the display.** The fork's renderer could
  hang there with the display off after sleep, and it papered over that by
  dropping renderer messages after a second. Sharp sets the swap interval
  to 0 instead, keeps Ghostty's never-dropping mailbox pushes, and paces
  frames to the display's refresh itself (`frame_pacer.zig`), a wait that
  is always bounded. It costs about 5 % of raw dump throughput.
- **Resizing never shows an empty or stale terminal.** WGL has no
  equivalent of Windows Terminal's `DXGI_SCALING_NONE` swap chain, so
  every pane resize waits (up to 16 ms) for the renderer's frame at the
  new size, panes keep their last frame when moved (no
  `SWP_NOCOPYBITS`), the window has `WS_CLIPCHILDREN` and fills newly
  exposed area with the terminal's color, and the sidebar's edge paints
  synchronously while dragged.
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
  when closing would end a program (`Subprocess.commandRunning`).
- **A tab's programs end with it.** Each shell starts inside its own Job
  Object (`PROC_THREAD_ATTRIBUTE_JOB_LIST`, so nothing escapes before it
  is assigned), which catches every program it launches even after the
  launcher exits. Closing the tab ends the console programs in the job
  first, then the shell. Programs built for the GUI subsystem (read from
  their PE header) and everything below them keep running, so `code .`
  or `start chrome` outlive the tab as they do in Windows Terminal.
- **Settings are a panel that writes the config file.** The gear, beside
  minimize, opens a panel over the dimmed terminal, laid out like T3
  Code's: searchable categories on the left, cards of settings with
  dropdowns and switches on the right. A change writes `key = value` to
  Ghostty's config file and reloads it, so the file stays the single
  source of truth. The panel is a per-pixel-alpha layered window drawn
  with `canvas.zig`, so it has no child controls; the search box is drawn
  too, and typing anywhere in the panel searches. Its text is JetBrains
  Mono, the terminal's own font, registered privately at startup from the
  copy Ghostty embeds, and its surfaces have no outlines, only fills. Dropdowns open native
  menus, themed through uxtheme's unnamed SetPreferredAppMode export, as
  Explorer and Notepad do.
- **Images use the kitty graphics protocol.** The bundled ConPTY passes it
  through (checked 2026-10-28 with OpenConsole 1.25; the inbox Windows
  ConPTY strips it). `chafa` picks it automatically via `TERM_PROGRAM`.
  Ghostty has no Sixel support.
- **Shell profiles work like Windows Terminal's.** The arrow beside "+"
  lists installed shells with their icons; Ctrl+Shift+1..9 opens the Nth
  in a new tab (unless the config binds that chord to something else),
  Shift+click opens it in a new window, and each tab shows its shell's icon. Visual Studio prompts come from every installation its
  installer records (the `_Instances` state files vswhere reads), and WSL
  distributions from the Lxss registry key. The
  Settings > Shell dropdown uses the same list.
- **Ctrl+, opens the settings panel**, not the config file: in Sharp the
  panel is the config UI. The file is under Settings > Advanced.
- **Two modes: Tabs and Workspace.** Workspace puts tabs in a sidebar
  (`window-tab-bar-position = sidebar`, off by default). The settings
  panel offers it under General as a mode, not as a tab option, since it
  changes how Sharp works rather than how tabs look. It is laid out like Citropy's thread list: a search box,
  sections for local, WSL and SSH servers, a group per folder (or server),
  and per tab its shell icon, title, age, and a red dot after a bell out
  of sight. The strip stays as the title bar with the active tab's title, and the terminal gets a rounded top-left corner.
- **The sidebar layout works by folder.** Every tab has a folder from the
  start (inherited or configured) that the shell's OSC 7 reports keep
  current; cmd.exe reports too, through a PROMPT prefix. The shell's type
  shows only in the icon. Groups fold per section and folder, tabs drag
  within their folder, and the right edge
  resizes the sidebar. The strip has no "+" in this mode: each
  folder, and the Local and WSL titles, show "+" (default shell) and an
  arrow (shell menu) on hover. On a title they ask for the folder first,
  with Windows' own picker.
- **The sidebar layout reopens what was open.** Tabs (profile, folder and
  server), the active tab, folded groups, the width and recent servers are
  saved as they change. A tab that was on a server reconnects.
  Closing a window keeps its tabs for next time; closing the last tab by
  hand empties the session.
- **SSH sessions are found by polling.** Windows doesn't announce them, so
  every 3 seconds one process snapshot is searched below each tab's shell
  for an SSH client (ssh.exe, PuTTY's plink.exe, or wsl.exe running ssh)
  and its command line parsed for the destination, user included. An ssh
  typed inside a WSL shell runs in Linux, out of Windows' sight.
- **Servers open from the sidebar.** Local, WSL (when installed) and
  Servers always show. Servers' "+" opens a box for `user@host`, and its
  arrow lists the hosts in `~/.ssh/config` and the servers used recently,
  including ones reached by typing ssh. The tab runs `ssh.exe` directly,
  as Windows Terminal's SSH profiles do, so it ends with the connection.
  Addresses are checked before reaching ssh, since a leading `-` would be
  read as an option.
- **OSC 7 works on Windows.** Upstream ignored it there. Paths must carry
  a drive letter, since a Linux path from WSL would break the folder new
  tabs start in, and the host check ignores case. As on other platforms,
  new tabs now open in the current tab's folder.
- **Two tab styles.** `window-tab-style` (a Sharp addition to Ghostty's
  config) picks Chrome's flowing tabs or Windows Terminal's flat ones.
- **Changes are checked by building locally, with no tests and no CI.**
  The owner's rule is that no tests are written or run, and Sharp is only
  built for Windows on the owner's PC, so neither Ghostty's workflows nor
  the fork's are kept.
- **Sharp has its own version (0.1.0), in `dist/windows/ghostty.rc`.**
  `TERM_PROGRAM_VERSION` keeps Ghostty's, which tells programs which
  Ghostty features to expect.
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

A frame is the renderer's work for it: updating and drawing, without the
wait for the display inside SwapBuffers. `python dist/windows/frame_benchmark.py
zig-out/bin/sharp.exe` runs the load on the second monitor without taking
focus, using `SHARP_FRAME_LOG` (`src/apprt/win32/frame_log.zig`, fed by a
small hook in the shared `src/renderer/Thread.zig` and `OpenGL.zig`).

Baseline, 2026-10-28, two runs each:

- ReleaseFast: 2.0 ms average, 8.6 to 9.8 ms worst.
- ReleaseSafe: 2.4 ms average, 9.0 to 11.9 ms worst.
- The dump takes about 24 s either way; ConPTY, not Sharp, sets that pace.

## Tech debt

- `App.zig`, `Surface.zig` and `Window.zig` in the Win32 runtime are each
  2,600 to 3,400 lines and mix several jobs. Upstream's GTK files are just as
  large, so splitting them makes merges from `winfork` harder.
- The frame-time benchmark is run by hand, not after every commit: it
  takes a minute and opens a window.
- Replies to programs that probe for image support travel back through
  ConPTY's input side, which reportedly drops APC replies. Tools that
  insist on a reply may not detect image support. Unverified.
- A saved session reopens shells, not their output or running programs.
- A console program started from the tab in a window of its own (`start
  cmd`) ends with the tab, since only the GUI subsystem marks a program
  as independent. If Sharp crashes, nothing ends: the jobs don't kill on
  close, so GUI programs in them survive a normal close.
- The exe's static imports that are not KnownDLLs (opengl32, dwmapi,
  wininet...) are still searched for in its own folder first, so a
  portable copy unzipped beside planted DLLs would load them. Only
  `uxtheme.dll` (loaded at runtime) is pinned to System32.
