#!/bin/bash
# Build, package and publish a Sharp release on GitHub, where the updater
# (src/apprt/win32/updater.zig) and the install command find it. The
# version is dist/windows/VERSION; raise it before each release.
#
# Usage: dist/windows/release.sh [--dry-run]
#
# --dry-run builds the installer, SHA256SUMS and install.ps1 in
# dist/windows/_release without tagging or publishing. Needs NSIS 3 and an
# authenticated gh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZIG="/c/dev/tools/zig-x86_64-windows-0.17.0/zig.exe"
MAKENSIS="/c/Program Files (x86)/NSIS/makensis.exe"
OUT_DIR="$SCRIPT_DIR/_release"
REPOSITORY="tinuxongit/sharp-terminal"

dry_run="${1:-}"
[[ -z "$dry_run" || "$dry_run" == --dry-run ]] || { echo "usage: release.sh [--dry-run]" >&2; exit 1; }

cd "$REPO_DIR"

version="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release.sh: VERSION must be X.Y.Z, not $version" >&2; exit 1; }
tag="v$version"
installer="Sharp-$version-x64-setup.exe"

# The tag must name the code that was built, and others must be able to see it.
if [[ "$dry_run" != --dry-run ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo "release.sh: commit or stash your changes first" >&2; exit 1; }
    git fetch --quiet origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "release.sh: push main to origin first" >&2; exit 1; }
    if git ls-remote --exit-code --tags origin "refs/tags/$tag" > /dev/null; then
        echo "release.sh: $tag is already released; raise dist/windows/VERSION" >&2
        exit 1
    fi
fi
echo "Releasing $tag"

prefix="$OUT_DIR/build"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
"$ZIG" build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    -Dsharp-version="$version" -Dsharp-release=true -p "$prefix"
"$SCRIPT_DIR/stage.sh" "$prefix" "$OUT_DIR/stage"

# makensis is a Windows program: it takes Windows paths, and its /D
# switches must not be rewritten by Git Bash.
MSYS_NO_PATHCONV=1 "$MAKENSIS" -V2 \
    -DVERSION="$version" -DVERSION4="$version.0" \
    -DSTAGE="$(cygpath -w "$OUT_DIR/stage")" \
    -DOUTFILE="$(cygpath -w "$OUT_DIR/$installer")" \
    "$(cygpath -w "$SCRIPT_DIR/installer.nsi")"
(cd "$OUT_DIR" && sha256sum "$installer" > SHA256SUMS)
sha256="$(cut -d' ' -f1 < "$OUT_DIR/SHA256SUMS")"
sed -e "s/{version}/$version/g" -e "s/{sha256}/$sha256/g" "$SCRIPT_DIR/install.ps1" > "$OUT_DIR/install.ps1"
echo "Built $OUT_DIR/$installer"

if [[ "$dry_run" == --dry-run ]]; then
    exit 0
fi

notes="Install or update from PowerShell:

\`\`\`powershell
irm https://github.com/$REPOSITORY/releases/download/$tag/install.ps1 | iex
\`\`\`

Sharp already installed updates itself."
gh release create "$tag" "$OUT_DIR/$installer" "$OUT_DIR/SHA256SUMS" "$OUT_DIR/install.ps1" \
    --target "$(git rev-parse HEAD)" --title "Sharp $version" \
    --notes "$notes" --generate-notes --latest
echo "Published $tag"
