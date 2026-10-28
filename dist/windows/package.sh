#!/bin/bash
# Build and package Sharp as a portable ZIP.
#
# Usage:
#   ./dist/windows/package.sh              # fast, x86_64
#   ./dist/windows/package.sh debug        # Debug build (Console subsystem)
#
# Output: dist/windows/sharp-windows-x64-<version>.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPTIMIZE="${1:-fast}"

cd "$REPO_DIR"

echo "Building sharp (optimize=$OPTIMIZE)..."
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize="$OPTIMIZE"

for resource in bin/sharp.exe bin/conpty.dll bin/OpenConsole.exe share/terminfo/ghostty.terminfo share/licenses/conpty/LICENSE.txt; do
    if [ ! -f "zig-out/$resource" ]; then
        echo "ERROR: Incomplete Windows build — zig-out/$resource not found" >&2
        exit 1
    fi
done

# Get version string
VERSION="$(powershell.exe -Command "& '.\\zig-out\\bin\\sharp.exe' --version" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')" || true
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --always 2>/dev/null || echo 'dev')"
fi
echo "Version: $VERSION"

# Create staging directory
STAGE_DIR="$REPO_DIR/dist/windows/_stage/sharp"
rm -rf "$REPO_DIR/dist/windows/_stage"
mkdir -p "$STAGE_DIR"

# Keep the matching console runtime pair beside the executable.
for binary in sharp.exe conpty.dll OpenConsole.exe; do
    cp "zig-out/bin/$binary" "$STAGE_DIR/"
    echo "  $binary"
done
mkdir -p "$STAGE_DIR/share/licenses/conpty"
cp zig-out/share/licenses/conpty/LICENSE.txt "$STAGE_DIR/share/licenses/conpty/"
echo "  share/licenses/conpty/LICENSE.txt"

# Copy share resources (themes, shell-integration)
if [ -d zig-out/share/ghostty ]; then
    mkdir -p "$STAGE_DIR/share/ghostty"
    cp -r zig-out/share/ghostty/themes "$STAGE_DIR/share/ghostty/"
    cp -r zig-out/share/ghostty/shell-integration "$STAGE_DIR/share/ghostty/"
    THEME_COUNT=$(ls "$STAGE_DIR/share/ghostty/themes/" 2>/dev/null | wc -l)
    echo "  share/ghostty/themes/ ($THEME_COUNT themes)"
    echo "  share/ghostty/shell-integration/"
fi

# Copy the terminfo source file. resourcesDir() (src/os/resourcesdir.zig)
# uses share/terminfo/ghostty.terminfo as the Windows sentinel; without it,
# theme loading silently fails on fresh extracts. The compiled terminfo
# tree contains symlinks Windows ZIP tools can't handle, so we ship only
# the plain-text source — native Windows apps don't read terminfo anyway,
# and WSL/SSH users get terminfo from the Linux side.
if [ -f zig-out/share/terminfo/ghostty.terminfo ]; then
    mkdir -p "$STAGE_DIR/share/terminfo"
    cp zig-out/share/terminfo/ghostty.terminfo "$STAGE_DIR/share/terminfo/"
    echo "  share/terminfo/ghostty.terminfo (resource sentinel)"
fi

# Create a minimal README
cat > "$STAGE_DIR/README.txt" << READMEEOF
Sharp — $VERSION

QUICK START
  1. Run sharp.exe
  2. Config file: %LOCALAPPDATA%\\ghostty\\config.ghostty
     (the legacy filename "config" is also supported)
  Keep conpty.dll and OpenConsole.exe beside sharp.exe.

KEYBOARD SHORTCUTS
  Ctrl+Shift+T        New tab
  Ctrl+Shift+W        Close tab/pane
  Ctrl+Shift+N        New window
  Ctrl+Shift+P        Command palette
  Ctrl+Shift+O        Split right
  Ctrl+Shift+E        Split down
  Ctrl+Shift+[ / ]    Navigate splits
  Ctrl+Shift+C / V    Copy / Paste
  Ctrl+Shift+F        Find
  Ctrl+Enter          Toggle fullscreen
  Ctrl+= / - / 0      Zoom in / out / reset
  Ctrl+,              Open config file

SHELL INTEGRATION (PowerShell)
  Windows PowerShell 5.1 (powershell.exe) and PowerShell 7 (pwsh.exe)
  load the bundled integration automatically when enabled.
  No PowerShell profile edit is required. Keep the share/ folder beside
  sharp.exe wherever you extract this portable package.
  The script is share/ghostty/shell-integration/powershell/ghostty-shell-integration.ps1.
  To disable integration, set shell-integration = none in your config.

For full documentation: https://ghostty.org/docs
READMEEOF
echo "  README.txt"

# Create ZIP
ZIP_NAME="sharp-windows-x64-${VERSION}.zip"
ZIP_PATH="$REPO_DIR/dist/windows/$ZIP_NAME"
rm -f "$ZIP_PATH"
cd "$REPO_DIR/dist/windows/_stage"
if command -v zip &>/dev/null; then
    zip -qr "$ZIP_PATH" sharp/
else
    # PowerShell can't zip from WSL UNC paths. Copy to Windows temp first.
    WIN_TEMP="$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')"
    WIN_TEMP_WSL="$(wslpath "$WIN_TEMP")"
    rm -rf "$WIN_TEMP_WSL/sharp-zip-stage"
    mkdir -p "$WIN_TEMP_WSL/sharp-zip-stage"
    cp -r "$REPO_DIR/dist/windows/_stage/sharp" "$WIN_TEMP_WSL/sharp-zip-stage/sharp"
    powershell.exe -Command "Compress-Archive -Path '${WIN_TEMP}\\sharp-zip-stage\\sharp' -DestinationPath '${WIN_TEMP}\\${ZIP_NAME}' -Force" 2>&1 | tr -d '\r'
    cp "$WIN_TEMP_WSL/$ZIP_NAME" "$ZIP_PATH" 2>/dev/null
    rm -rf "$WIN_TEMP_WSL/sharp-zip-stage" "$WIN_TEMP_WSL/$ZIP_NAME"
fi

# Clean up staging
rm -rf "$REPO_DIR/dist/windows/_stage"

if [ -f "$ZIP_PATH" ]; then
    SIZE=$(du -h "$ZIP_PATH" | cut -f1)
    echo ""
    echo "Package created: dist/windows/$ZIP_NAME ($SIZE)"
else
    echo "ERROR: Failed to create ZIP"
    exit 1
fi
