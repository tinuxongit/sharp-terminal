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

# Sharp's own version; sharp.exe --version prints Ghostty's.
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
echo "Version: $VERSION"

# Stage the payload (payload.txt) as Sharp runs from it.
STAGE_DIR="$REPO_DIR/dist/windows/_stage/sharp"
rm -rf "$REPO_DIR/dist/windows/_stage"
"$SCRIPT_DIR/stage.sh" zig-out "$STAGE_DIR"

# Create a minimal README
cat > "$STAGE_DIR/README.txt" << READMEEOF
Sharp — $VERSION

QUICK START
  1. Run sharp.exe
  2. Config file: %LOCALAPPDATA%\\ghostty\\config.ghostty
     (the legacy filename "config" is also supported)
  Keep conpty.dll, OpenConsole.exe and WebView2Loader.dll beside sharp.exe.

KEYBOARD SHORTCUTS
  Ctrl+Shift+T        New tab
  Ctrl+Shift+W        Close tab/pane
  Ctrl+Shift+N        New window
  Ctrl+Shift+P        Command palette
  Ctrl+Shift+O        Split right
  Ctrl+Shift+E        Split down
  Ctrl+Shift+[ / ]    Navigate splits
  Ctrl+C / Ctrl+V     Copy (a selection) / Paste
  Ctrl+Shift+F        Find
  Ctrl+Enter          Toggle fullscreen
  Ctrl+= / - / 0      Zoom in / out / reset
  Ctrl+,              Settings

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
