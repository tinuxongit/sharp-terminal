# Contributing to Sharp

## Build

Install [Zig](https://ziglang.org/download/) 0.17.0 and build the Windows
app with the GNU target (the default MSVC target fails):

```
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

The app lands in `zig-out\bin\sharp.exe`. A change is checked by building
it, as CI does on every push; Sharp keeps no test suites.

## Where things live

`CLAUDE.md` lists which file owns what, the decisions behind the design,
and the performance budget. Read it before changing anything. In short:
`src/apprt/win32/` is the Windows app, everything else in `src/` is the
terminal core shared with Ghostty, and content (settings, shell profiles,
text) lives in the `.zon` data files beside the code that reads them.

## Keeping up with Ghostty

The core comes from Ghostty (`upstream`). Keep changes to shared files
small and say in the commit why they are needed, so merges from upstream
stay easy. Windows-only work belongs in `src/apprt/win32/`.

## Performance

Changes to rendering or output handling must stay within the budget:
4 ms per frame on average and 16 ms at worst under the load in
`dist/windows/frame_benchmark.py`, which a post-commit hook runs (see
CLAUDE.md).

## Commits

Commit each change that works, with a message that says why. Comments in
code explain why it exists, never what it does.
