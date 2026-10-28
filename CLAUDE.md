# Sharp

Sharp is a native Windows terminal emulator. It is a fork of
[shiweis/ghostty-windows](https://github.com/shiweis/ghostty-windows), which is
itself a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a
Win32 app runtime. All three are MIT licensed. `AGENTS.md` has the upstream
commands and conventions; this file covers what is specific to Sharp.

## Remotes

- `upstream`: ghostty-org/ghostty. The shared terminal core comes from here.
- `winfork`: shiweis/ghostty-windows. The Win32 runtime comes from here.
- `origin`: tinuxongit/sharp-terminal on GitHub, public. Sharp's own
  work is pushed there.

## Who owns what

- `src/apprt/win32/`: the Windows app (windows, tabs, splits, input, IME,
  clipboard, quick terminal). `win32.zig` holds the raw Win32 API bindings.
  `App.zig` runs the app and its message loop, `Window.zig` is a window
  with its tabs and layout, `Surface.zig` is one terminal pane. Their
  other jobs are split out, and Ghostty has no Windows runtime, so
  splitting them costs no merges:
  - `actions.zig`: carries out each action the core asks for.
  - `window_messages.zig`, `pane_messages.zig`: where each Windows message
    to a window or a pane goes.
  - `workspace.zig`: Workspace mode's side of a window (grouping, the
    sidebar's input, opening tabs in folders or on servers, SSH polling).
  - `splits.zig`, `tab_rename.zig`, `strip_mouse.zig`: split panes, renaming
    a tab in place, the tab strip's mouse.
  - `pane_mouse.zig`, `clipboard.zig`, `ime.zig`, `win32_input.zig`,
    `key_map.zig`: a pane's mouse, clipboard, input methods, ConPTY's
    mode 9001 and Windows keys in Ghostty's terms.
  - `find_bar.zig`, `command_palette.zig`: a pane's find bar and command
    palette.
  - `global_hotkey.zig`: the quick terminal's system-wide hotkey.
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
- `src/apprt/win32/load_config.zig`: the exe's PE load configuration.
- `src/apprt/win32/frame_pacer.zig`: one frame per display refresh for each
  renderer thread.
- `src/apprt/win32/clipboard_keys.zig`: Windows' copy and paste keys
  (`clipboard-keys`), added to the config as it loads.
- `src/apprt/win32/background_style.zig`: Sharp's background styles
  (`background-style`): makes the style's tile for its color (sizes in
  `backgrounds.zon`, written by `png.zig`) and hands it to Ghostty as the
  background image when the config loads (`App.loadConfig`).
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
- `src/apprt/win32/sidebar_usage.zig`: the sidebar's AI section, a card
  per tool with its plan windows or spending.
- `src/apprt/win32/logos.zon`: the tools' logos as outlines, made by
  `dist/windows/make_logos.py` from the SVGs in `dist/windows/logos/`
  (thesvg.org: Claude, OpenAI and opencode, under MIT or CC0).
  `logos.zig` fills them, anti-aliased, by either fill rule, at any size.
- `src/apprt/win32/session.zig`: saves and loads the sidebar layout's
  open tabs (`sharp-session`, beside the config file).
- `src/apprt/win32/process_tree.zig`: all processes at one moment and
  which run below a tab's shell, for the sidebar layout's polling.
  `ssh.zig` finds the server a tab's ssh is connected to;
  `claude_session.zig` the Claude Code conversation a tab is running.
- `src/apprt/win32/ai_usage.zig`: reads Claude's and Codex's plan windows
  and OpenCode's spending through their CLIs, on a background thread, for
  the sidebar's AI section.
- `src/apprt/win32/servers.zig`: the servers the sidebar offers (hosts in
  `~/.ssh/config` and recent ones), and which addresses ssh may be given.
- `src/apprt/win32/BrowserPanel.zig`: the browser panel, a child window
  with its tabs, where pages sit in it, and its painting.
  `browser_messages.zig` is where its Windows messages go (toolbar,
  address box, shortcuts, dragging its edge).
- `src/apprt/win32/browser_settings.zig`: reads `browser.zon` (sizes,
  fixed page size, tab limit, search engines, text) and says what a typed
  address means.
- `src/apprt/win32/BrowserTab.zig`: one tab's page, title, history and
  log. `browser_engine.zig` is the WebView2 side: the browser process,
  each tab's page and its preparation (Chrome identity, fixed size), and
  page events.
- `src/apprt/win32/browser_toolbar.zig`: the panel's toolbar (tabs, back,
  forward, reload, address box), its layout and painting.
- `src/apprt/win32/browser_log.zig`: what a page logged (console,
  uncaught errors, failed loads) for Claude.
- `src/apprt/win32/browser_dock.zig`: a window's side of the panel: the
  globe, where the panel sits, and opening, hiding and freeing it.
- `src/apprt/win32/webview2.zig`: the WebView2 COM interfaces the panel
  calls, and loading `WebView2Loader.dll` (pinned in `pkg/webview2/`).
- `src/apprt/win32/browser_tools.zon`: the tools Claude is offered (names,
  descriptions, input schemas). `browser_tools.zig` runs them on
  `browser_page.zig`, a tab seen from the MCP server's thread;
  `browser_snapshot.zig` turns the accessibility tree into Claude's text,
  `browser_remote.zig` carries their calls to the UI thread, and
  `json_read.zig` reads the JSON that comes back.
- `src/apprt/win32/mcp_server.zig`: Sharp's MCP server (JSON-RPC over a
  named pipe only the user can open, `mcp_pipe.zig`). `mcp_bridge.zig` builds
  `sharp-mcp.exe`, the command Claude Code runs, which relays its stdio to
  that pipe.
- `src/apprt/win32/claude_mcp.zig`: adds Sharp to Claude Code's MCP
  servers, or removes it, when the browser setting changes.
- `src/apprt/win32/folder_picker.zig`: Windows' folder picker, behind the
  buttons on a sidebar section's title.
- `src/termio/cmd_prompt.zig`: makes cmd.exe report its folder (OSC 7)
  through its PROMPT.
- `src/apprt/win32/SearchField.zig`: the search box shared by the settings
  panel and the tab sidebar.
- `src/apprt/win32/spots.zig`: clickable regions recorded while painting.
- `src/apprt/win32/config_file.zig`: reads and changes one key of the
  user's Ghostty config file, leaving the rest of it untouched.
- `src/apprt/win32/default_terminal.zig`: makes Sharp Windows' default
  terminal and gives the previous choice back (the registry side).
  `terminal_handoff.zig` is the COM class Windows Terminal's console hands
  each console to; `src/os/console_handoff.zig` keeps it until its tab's
  IO thread takes it (`Pty.adopt` in `src/pty.zig`).
- `src/apprt/win32/elevation.zig`: administrator tabs: whether Sharp is
  elevated, and opening a profile in an elevated Sharp.
- `src/apprt/win32/tab_color.zig`: a tab's color and its picker
  (`tab_colors.zon`); the color lives on the tab's panes, like its icon.
- `src/apprt/win32/tab_order.zig`: Ctrl+Tab in the order tabs were last
  used (`tab-switch-order = recent`).
- `src/apprt/win32/mark_mode.zig`: selecting with the keyboard and
  block selection; `shell_open.zig` shows a folder in Explorer.
- `src/apprt/win32/startup.zig`: starting Sharp at sign-in.
- `src/apprt/win32/ipc.zig`: `sharp +new-tab` and `+new-window` reaching
  a running Sharp.
- `src/apprt/win32/jump_list.zig`: the taskbar's list of shells.
  `command_line.zig` quotes one argument of a Windows command line.
- `src/apprt/win32/closed_tabs.zig`: the last ten closed tabs, for
  reopening.
- `src/apprt/win32/user_environment.zig`: the variables a new tab starts
  with.
- `src/apprt/win32/updater.zig`: finds, downloads and verifies a newer
  release on a background thread, and runs its installer. `updates.zon`
  holds the repository, timings, asset names and text;
  `release_version.zig` reads and orders release versions; `https.zig`
  fetches over WinHTTP.
- `dist/windows/VERSION`: Sharp's version, read by the build
  (`-Dsharp-version`) for the exe's version resource and the updater.
- `dist/windows/payload.txt`: the files a Sharp install holds, read by
  `stage.sh` (for `package.sh` and `release.sh`) and `install-dev.ps1`.
- `dist/windows/installer.nsi`: the NSIS installer and uninstaller.
- `dist/windows/release.sh`: builds, packages and publishes a release on
  GitHub (`--dry-run` stops before publishing).
- `dist/windows/install.ps1`: the install command's script; `release.sh`
  fills in the version and checksum and publishes it with each release.
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
  or `start chrome` outlive the tab as they do in Windows Terminal; so do
  console programs in a console someone can see (`start cmd`, or another
  terminal's pseudo console), told apart by the process hosting their
  console. A crash (panic, segfault or unhandled exception) ends every
  tab's console programs the same way before the process dies.
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
  ConPTY strips it), both ways: a program's kitty query gets its
  `ESC _Gi=31;OK ESC \` reply on input, so tools that wait for one detect
  image support. `chafa` picks it automatically via `TERM_PROGRAM`.
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
- **`sharp +new-tab` and `+new-window` open in the running Sharp**, as
  `wt -w 0 nt` does. Ghostty's CLI actions call `performIpc`; on Windows
  the command sends its arguments (`-e`, `--command`,
  `--working-directory`, `--title`, read as GTK reads them) with
  WM_COPYDATA to a running Sharp's message window, letting it come to the
  front. With none running, or only an elevated one Windows keeps it from
  reaching, it starts Sharp with those arguments. Checked 2026-10-28.
  The installer adds "Open in Sharp" for folders, drives and a folder's
  background (`sharp +new-tab "--working-directory=%V\."`; the `\.`
  keeps a drive root's backslash from escaping the quote). Windows 11
  lists it under "Show more options": its top menu takes only signed
  packages. Checked 2026-10-29 with a real install and uninstall.
- **Startup works as in Windows Terminal.** Settings > General >
  Startup: Start with Windows (`start-at-login`, a value under the
  user's Run key), Reopen tabs (Ghostty's `window-save-state = always`,
  which on Windows reopens the Tabs layout's tabs as the sidebar layout
  always does), Open maximized (Ghostty's `maximize`, with `fullscreen`
  honored too) and Center new windows (`window-center`). Checked
  2026-10-28 that the switch adds and removes the Run value.
- **The sidebar layout reopens what was open.** Tabs (profile, folder and
  server), the active tab, folded groups, the width and recent servers are
  saved as they change. A tab that was on a server reconnects.
  Closing a window keeps its tabs for next time; closing the last tab by
  hand empties the session. Tabs come back with their shell and folder,
  not their old output: the programs that wrote it can't come back, and
  output alone isn't worth saving.
- **Claude Code conversations come back with their tabs.** The same
  3-second poll finds claude.exe below each tab's shell and reads the
  file Claude Code keeps for each running process,
  `~/.claude/sessions/<pid>.json` (or under `CLAUDE_CONFIG_DIR`), for its
  session id and folder; Sharp touches nothing of Claude Code's. The
  session file keeps them as a fourth field, with the tab's folder set to
  Claude's, since conversations are kept per folder. A reopened tab whose
  conversation was saved (`projects/<folder>/<id>.jsonl` exists; Claude
  saves only once a message is sent) gets `claude --resume <id>` typed
  into its shell, so the shell remains after Claude exits. The id must be
  a UUID before it is saved or typed. Not in WSL tabs, whose claude would
  be another install. Settings > AI > Claude > Resume conversations
  (`ai-resume-claude`, on by default) turns it off. Checked 2026-10-28
  with a throwaway Claude config: a saved conversation resumed, an unsaved
  one typed nothing.
- **SSH sessions are found by polling.** Windows doesn't announce them, so
  every 3 seconds one process snapshot is searched below each tab's shell
  for an SSH client (ssh.exe, PuTTY's plink.exe, or wsl.exe running ssh)
  and its command line parsed for the destination, user included. An ssh
  typed inside a WSL shell runs in Linux, out of Windows' sight.
- **Servers open from the sidebar.** Local, WSL (when installed) and
  Servers always show; one without tabs is shorter and dimmed until
  hovered, so the ones in use stand out. Servers' "+" opens a box for `user@host`, and its
  arrow lists the hosts in `~/.ssh/config` and the servers used recently,
  including ones reached by typing ssh. The tab runs `ssh.exe` directly,
  as Windows Terminal's SSH profiles do, so it ends with the connection.
  Addresses are checked before reaching ssh, since a leading `-` would be
  read as an option.
- **The sidebar shows AI usage, read through each tool's CLI.** An AI
  section pinned at its foot shows a card per tool, with its logo: Claude's and Codex's plan windows ("5-hour
  limit", "71% left", a bar that empties, "Resets in 1h 18m" or "Resets
  Nov 24") and OpenCode's spending today and this week, for whichever is installed
  and switched on in Settings > AI (`ai-usage-claude`, `ai-usage-codex`,
  `ai-usage-opencode`), refreshed every 5 minutes. Each plan's windows
  switch on and off by kind (`-session`, `-weekly`, `-models` after the
  tool's key): the short window, the weekly one, and the per-model ones
  (Claude's `model_scoped`, such as Fable; Codex's other
  `rateLimitsByLimitId` entries), so a new model needs no new setting. Clicking its title folds
  it, remembered in the session like a folded group. Claude Code
  is asked as T3 Code asks it: started in stream-json mode with hooks and
  MCP off, never given a prompt, and sent the `get_usage` control request
  its /usage uses. It reads its own credentials, so Sharp touches no token
  and no Claude setting, and an API key simply shows "no plan limits".
  The request is marked experimental in Anthropic's Agent SDK, so the
  reply is read loosely and a failed read keeps the last one. The
  undocumented `/api/oauth/usage` endpoint other tools call was rejected:
  it needs the user's token and Claude Code's User-Agent, and may break
  Anthropic's consumer terms. Codex is asked as T3 Code asks it too: its
  `app-server` answers the JSON-RPC request `account/rateLimits/read`.
  OpenCode answers `opencode stats --json --cost --standalone`, which
  leaves no background service behind.
- **A browser beside the terminal, off until switched on.** Settings > AI
  > Tools > Browser (`ai-tools-browser`, off by default) adds a globe
  beside the gear, and its first click creates the panel. Until then Sharp
  loads no browser at all: checked 2026-10-28, no `WebView2Loader.dll` in
  the process and no `msedgewebview2.exe`. The page is WebView2, the Edge
  runtime Windows ships, driven through its COM API with the loader
  pinned and loaded by full path like ConPTY; Electron or CEF would ship a
  second Chromium. Sharp draws the toolbar and its tabs (up to 12;
  Ctrl+T, Ctrl+W, Ctrl+L and Ctrl+Tab work as in Chrome). Hiding the
  panel keeps its pages, closing its last tab hides it, switching the
  setting off frees it, and logins stay in
  `%LOCALAPPDATA%\Sharp\Browser`, apart from Edge's. A page opening a
  window gets a tab that is that window (`put_NewWindow`), so sign-in
  popups keep their `opener`. New tabs open the search engine chosen in
  Settings > AI > Tools (`browser-search-engine`: Google or DuckDuckGo).
  The panel's edge drags. The design follows Citropy's browser rather
  than T3 Code's, which is a preview of a dev server.
- **Every page is 1920 × 1080, scaled to fit, as in Citropy.** Claude
  always sees the same desktop layout and coordinates however wide the
  panel is. `Emulation.setDeviceMetricsOverride` with its `scale` fits the
  page into a 16:9 box centered below the toolbar, and the user's own clicks are
  mapped back into the page (checked 2026-10-28: the middle of the shown
  page lands at 960 × 540). The cost is small text in a narrow panel; the
  size is in `browser.zon`.
- **Sites see Chrome, not WebView2.** WebView2 says "Edg/" and "Microsoft
  Edge WebView2" in its user agent and client hints, and some sites
  refuse embedded browsers. Before a page loads anything, it gets the
  user agent without "Edg/", client hints naming Chromium and Google
  Chrome with the grease brand Chromium would add, Windows' platform
  version from the registry, and the user's language, through
  `Emulation.setUserAgentOverride`. Checked against httpbin: the headers
  match a Chrome of the same version.
- **Claude reaches the browser over MCP, only while the switch is on.**
  Turning Settings > AI > Tools > Browser on starts Sharp's MCP server
  and runs `claude mcp add --scope user sharp -- <dir>\sharp-mcp.exe`;
  turning it off stops the server and runs `claude mcp remove`. That is
  the only change Sharp makes to Claude Code's configuration. Claude Code
  runs `sharp-mcp.exe`, which relays its stdio to a named pipe named after
  the Windows user, so the tools act on the panel the user sees. The pipe
  is created first-instance-only, closed to remote clients, and with a
  DACL for the user alone (the default lets everyone read it); the bridge
  refuses a pipe whose server runs as another user. Claude may open only
  http and https addresses, so a page can't steer it to `file://` or the
  browser's own pages. The tools are Citropy's core: `browser_open`,
  `browser_tabs`, `browser_close`, `browser_snapshot` (the accessibility
  tree with `[ref=N]` handles, plus a 1920 × 1080 JPEG in the coordinates
  clicks use), `browser_action` (navigate, back, forward, reload, click,
  hover, type, press, scroll, wait, evaluate) and `browser_logs`, all
  through DevTools calls on the page. A tool's tab becomes the visible
  one, so the user sees what Claude does. Citropy's iframes, uploads,
  dialogs, mobile emulation and connected accounts are left out. Checked
  2026-10-28 through the real protocol and against a throwaway Claude
  Code config (`claude mcp list`: connected).
- **Copy and paste use Windows' keys.** `clipboard-keys = windows`, the
  default, binds `performable:ctrl+c=copy_to_clipboard` and
  `performable:ctrl+v=paste_from_clipboard` on the loaded config, unless
  the file binds those chords. Ctrl+C copies only a selection and
  otherwise interrupts, as in Windows Terminal; Ctrl+V pastes only text or
  files, so with an image on the clipboard the key reaches the program
  (Claude Code reads the image itself). Settings > General offers
  Ghostty's Ctrl+Shift+C/V instead. Files dropped on a terminal are
  pasted as quoted paths, a bracketed paste, so Claude Code takes an
  image's path as an attachment. Each profile says how its shell writes
  paths (`.paths` in `profiles.zon`, Windows Terminal's
  `pathTranslationStyle`): WSL tabs get `/mnt/c/...` (and a distribution's
  own `\wsl.localhost` share its root), Git Bash `/c/...`, both in single
  quotes, which expand nothing.
- **Background styles are tiles Ghostty already knows how to draw.**
  Settings > Appearance > Background offers Default (the plain theme
  color) and Pixel cascade, a grid of squares in any color
  (`background-style-color`, the text color by default) that thins out
  over the top of the terminal. Ghostty's renderer draws images, not
  patterns, so Sharp makes a small repeating PNG per color in
  `%LOCALAPPDATA%\Sharp\Backgrounds` and sets `background-image` (and
  its position, fit and repeat) on the loaded config, never in the file,
  so the shared renderer is untouched. The panel no longer offers
  background opacity, which showed the desktop through the sidebar too;
  `background-opacity` in the file still works.
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
- **DLLs load from System32 only.** The exe's load configuration
  (`load_config.zig`, the `_load_config_used` symbol LLD picks up) sets
  `DependentLoadFlags` to System32, so a dwmapi.dll or opengl32.dll planted
  beside a portable copy is ignored; checked 2026-10-28 by planting junk
  copies of each non-KnownDLL import. Windows ignores the field unless the
  structure has its full Windows 10 size (0x140).
- **Administrator tabs open in an elevated window, as in Windows
  Terminal.** An unelevated process can't start an elevated console, so
  Ctrl+click on a profile (the "+" menu and the sidebar's menus) starts
  Sharp as administrator through `runas` with `--command` and
  `--working-directory`. An elevated Sharp shows a shield before its tabs
  and "Administrator:" in its title, and neither restores nor saves the
  session, installs updates or takes default-terminal consoles. Checked
  2026-10-28 that those arguments open the profile in the folder; the
  consent prompt itself needs a person.
- **Pane actions are one new Ghostty action, `split_pane`.** Windows
  Terminal's swap, flip orientation, move to new tab, close others and
  broadcast input are `split_pane:swap_next` and so on, in the palette
  and bindable, so the shared code gains one action rather than six.
  Swapping wraps around, as in Windows Terminal. Broadcast copies what
  Sharp's Win32 input mode writes for typed keys, text and IME to the
  tab's other panes (an antenna marks the tab); pastes go through
  Ghostty's core and aren't broadcast. Sharp's palette has its own list
  (`command_palette.zig`), not Ghostty's `command.zig`.
- **Sharp's own actions are one Ghostty action, `sharp`.** Windows-app
  actions that Ghostty lacks (`sharp:search_web`, `open_folder`,
  `mark_mode`, `block_selection`) are values of a single action, so new
  ones add an enum value instead of plumbing a whole action through the
  shared code. Search the web goes through `open_url`, as typed text,
  with the browser setting's search engine (`browser_settings.searchAddress`).
  Mark mode starts a selection at the cursor; arrows, Page Up/Down, Home
  and End extend it, Enter copies, Escape leaves, and any other key ends
  it but goes through, keeping the selection.
- **Closed tabs reopen as the session would restore them.** Windows has
  no undo manager, so Ghostty's `undo` ("Reopen Closed Tab" in Sharp's
  palette and the tab menu) reopens the last of ten closed tabs: shell,
  folder, server and Claude conversation, not output. It has no key by
  default, as in Windows Terminal; Ctrl+Shift+T stays "new tab".
- **New tabs see the environment Windows has now.** Each tab starts from
  Sharp's own variables overlaid with the user's as Windows builds them
  for a new sign-in (`CreateEnvironmentBlock`), as Windows Terminal's
  `reloadEnvironmentVariables` does, so a PATH an installer changed
  reaches the next tab without restarting Sharp. Variables only Sharp's
  launcher set still pass through; a PATH it changed doesn't.
- **Sharp can be Windows' default terminal.** Settings > General >
  Default terminal (`default-terminal`, off by default): console programs
  started from Explorer, the Run box or the Start menu open in a Sharp
  tab, as with Windows Terminal. Windows' own setting lists only packaged
  (MSIX) terminals, and packaging needs signing, so Sharp writes the same
  two values itself (`DelegationConsole`, `DelegationTerminal` in
  `HKCU\Console\%%Startup`). Windows Terminal's console stays the console
  host and hands each console to Sharp's COM class through
  `ITerminalHandoff3`; the tab wraps it with `ConptyPackPseudoConsole`
  from the bundled ConPTY and puts its program in a job like a shell's.
  The call needs `OpenConsoleProxy.dll`, which Windows won't load from
  Windows Terminal's folder into another app (access denied), so Sharp
  ships the copy from Windows Terminal 1.24's portable zip, pinned by hash
  in `build.zig.zon`, x64 only. Switching on remembers the previous
  choice under `HKCU\Software\Sharp`; switching off, or uninstalling,
  puts it back unless another terminal was chosen since. When Sharp
  isn't running, Windows starts it with `-Embedding`: it restores its
  session as usual but opens no shell of its own, and waits up to 30 s
  for the console. Needs Windows Terminal installed, as it is on Windows
  11. Checked 2026-10-28 with throwaway config: a cmd started outside
  Sharp opened as a tab, in a running Sharp and in one Windows started,
  and the switch and the uninstaller each restored the previous choice.
- **Sharp has its own version, in `dist/windows/VERSION`.** The build
  writes it into the exe's version resource. `TERM_PROGRAM_VERSION` keeps
  Ghostty's, which tells programs which Ghostty features to expect.
- **Sharp installs and updates itself as T3 Code does.** The installer is
  NSIS, one-click and per user: no wizard, no admin rights,
  `%LOCALAPPDATA%\Programs\Sharp`, a Start Menu shortcut, a desktop one
  on the first interactive install, and an entry in Installed apps.
  Releases are `vX.Y.Z` on GitHub, cut from main, each with its
  installer, `SHA256SUMS` and `install.ps1`; there is no nightly channel
  for now, and prereleases are ignored. Sharp asks GitHub's API 20 s
  after starting and then every 4 minutes, downloads a newer installer in
  the background, and installs it only if the hash matches. A green button
  beside the gear restarts into it; otherwise it installs silently when
  Sharp quits. Ghostty's `auto-update` key (`off` stops it) drives it,
  offered under Settings > General > Updates. A local build (without
  `-Dsharp-release`) never updates. The installer waits for a running
  Sharp to let go of its files before replacing them. Checked 2026-10-28:
  silent install, waiting on a locked `sharp.exe`, a clean uninstall, and
  a local 0.0.9 build that found v0.1.0 on GitHub within 25 s, showed the
  button, and restarted as 0.1.0 about 4 s after the click.
- **Sharp is installed by a PowerShell command, not a downloaded file.**
  There is no code signing (T3 Code pays for Azure Trusted Signing), and
  SmartScreen stops unsigned programs only when they carry the mark of
  the web, which browsers add and PowerShell doesn't (checked 2026-10-28).
  So the README offers only `irm .../releases/latest/download/install.ps1
  | iex`, which downloads the installer, checks it against the hash
  written into the script, and runs it. Updates download through WinHTTP
  and carry no mark either. The installer stays a release asset, since
  the updater needs it. Smart App Control, on only on some fresh Windows
  11 installs, still blocks unsigned programs.
- **Sharp to people, Ghostty to programs.** The exe, window text, dialogs,
  version info, the command palette, messages printed in the terminal and
  the CLI's own text (`+version` shows Ghostty's version below Sharp's)
  say Sharp. Where Windows lists programs (Task Manager, Installed apps,
  the Start menu) it is "Sharp Terminal"; the install folder, uninstaller
  and registry key stay "Sharp" so updates find the copy installed. `TERM_PROGRAM`, terminfo, `GHOSTTY_*` variables,
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

After every commit that changes code, the post-commit hook
(`dist/windows/hooks/post-commit`, installed with `git config
core.hooksPath dist/windows/hooks`) runs `dist/windows/bench-commit.sh` in
the background: it builds into `zig-out-bench` and runs the benchmark
against `dist/windows/frame_baseline.json`. A broken budget, or an
average 30 % over the baseline, shows a Windows notification;
`.git/sharp-bench.log` keeps every result. Re-save the baseline with
`--save-baseline` after a deliberate change in cost.

Measured 2026-10-28, two runs each, before frame pacing:

- ReleaseFast: 2.0 ms average, 8.6 to 9.8 ms worst.
- ReleaseSafe: 2.4 ms average, 9.0 to 11.9 ms worst.
- The dump takes about 24 s either way; ConPTY, not Sharp, sets that pace.

## Tech debt

None.
