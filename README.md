<h1 align="center">
  <img src="dist/windows/logo.png" alt="" width="96"><br>
  Sharp
</h1>
<p align="center">A fast, native terminal for Windows.</p>

## What it does

- **Native and GPU-rendered.** A Win32 app drawn with OpenGL, one `.exe`
  with no WSL, Cygwin or Electron underneath.
- **Tabs in the title bar.** Choose Chrome's flowing tabs or Windows
  Terminal's flat ones. Tabs shrink as you open more, close with a middle
  click, and drag to reorder.
- **Workspace mode.** Tabs move to a searchable sidebar grouped into Local,
  WSL and Servers, and then by folder. Each folder has "+" for your default
  shell and an arrow for any other. Servers lists the hosts in
  `~/.ssh/config` and the ones you used recently. Sharp reopens what you
  had open.
- **Every shell you have.** PowerShell, Command Prompt, PowerShell 7, Git
  Bash, Visual Studio developer prompts and each WSL distribution, with
  their icons. `Ctrl+Shift+1` to `9` opens the Nth one.
- **A settings panel.** `Ctrl+,` opens searchable settings that write
  your config file for you.
- **Images in the terminal** through the kitty graphics protocol (for
  example `chafa photo.jpg`).
- **Splits, search, a quick terminal on a global hotkey**, and links that
  open only when they are safe to.

## Building

Install [Zig](https://ziglang.org/download/) 0.17.0, then:

```
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

The GNU target is required; the default MSVC one fails. The app lands in
`zig-out\bin\sharp.exe`, beside the `conpty.dll` and `OpenConsole.exe` it
needs. `bash dist/windows/package.sh` makes a portable
`sharp-windows-x64-<version>.zip`.

## Configuration

Most settings are in the panel (`Ctrl+,`). Everything else goes in
`%LOCALAPPDATA%\ghostty\config.ghostty` as `key = value` lines:

```
font-family = JetBrains Mono
font-size = 13
theme = Catppuccin Mocha
window-tab-bar-position = sidebar
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

Sharp uses Ghostty's config format, so every option and theme in the
[Ghostty documentation](https://ghostty.org/docs/config) works here, and
programs that support Ghostty treat Sharp the same way.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| New tab / window | `Ctrl+Shift+T` / `Ctrl+Shift+N` |
| Open the Nth shell | `Ctrl+Shift+1` to `9` |
| Close tab or pane | `Ctrl+Shift+W` |
| Next / previous tab | `Ctrl+Page Down` / `Ctrl+Page Up` |
| Split right / down | `Ctrl+Shift+O` / `Ctrl+Shift+E` |
| Copy / paste | `Ctrl+Shift+C` / `Ctrl+Shift+V` |
| Find | `Ctrl+Shift+F` |
| Settings | `Ctrl+,` |
| Font size | `Ctrl+=`, `Ctrl+-`, `Ctrl+0` |

Every shortcut can be changed with `keybind` in the config file.

## Performance

`python dist/windows/frame_benchmark.py zig-out\bin\sharp.exe` dumps a
50 MB file and scrolls through it, then reports frame times against the
budget of 4 ms on average and 16 ms at worst.

## License

MIT. See [LICENSE](LICENSE).
