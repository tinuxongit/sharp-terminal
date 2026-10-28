#!/bin/bash
# Build, package and publish a Sharp release on GitHub, where the updater
# (src/apprt/win32/updater.zig) finds it. Channels work as T3 Code's:
#
#   stable   vX.Y.Z from dist/windows/VERSION, marked latest
#   nightly  vX.Y.(Z+1)-nightly.YYYYMMDD.N, a prerelease
#
# Usage: dist/windows/release.sh stable|nightly [--dry-run]
#
# --dry-run builds the installer and SHA256SUMS in dist/windows/_release
# without tagging or publishing. Needs NSIS 3 and an authenticated gh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZIG="/c/dev/tools/zig-x86_64-windows-0.17.0/zig.exe"
MAKENSIS="/c/Program Files (x86)/NSIS/makensis.exe"
OUT_DIR="$SCRIPT_DIR/_release"

channel="${1:-}"
dry_run="${2:-}"
[[ "$channel" == stable || "$channel" == nightly ]] || { echo "usage: release.sh stable|nightly [--dry-run]" >&2; exit 1; }

cd "$REPO_DIR"

# The tag must name the code that was built, and others must be able to see it.
if [[ "$dry_run" != --dry-run ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo "release.sh: commit or stash your changes first" >&2; exit 1; }
    git fetch --quiet origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "release.sh: push main to origin first" >&2; exit 1; }
fi

# The next nightly run of today, counted from the tags already on origin.
next_nightly() {
    local base="$1"
    local date
    date="$(date -u +%Y%m%d)"
    local count
    count="$(git ls-remote --tags origin "refs/tags/v$base-nightly.$date.*" | wc -l)"
    echo "$base-nightly.$date.$((count + 1))"
}

stable_version="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
if [[ "$channel" == stable ]]; then
    version="$stable_version"
    if git ls-remote --exit-code --tags origin "refs/tags/v$version" > /dev/null; then
        echo "release.sh: v$version is already released; raise dist/windows/VERSION" >&2
        exit 1
    fi
else
    IFS=. read -r major minor patch <<< "$stable_version"
    version="$(next_nightly "$major.$minor.$((patch + 1))")"
fi
tag="v$version"
core="${version%%-*}"
run="0"
[[ "$version" == *-* ]] && run="${version##*.}"
installer="Sharp-$version-x64-setup.exe"
echo "Releasing $tag ($channel)"

prefix="$OUT_DIR/build"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
"$ZIG" build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    -Dsharp-version="$version" -Dsharp-channel="$channel" -p "$prefix"
"$SCRIPT_DIR/stage.sh" "$prefix" "$OUT_DIR/stage"

# makensis is a Windows program: it takes Windows paths, and its /D
# switches must not be rewritten by Git Bash.
MSYS_NO_PATHCONV=1 "$MAKENSIS" -V2 \
    -DVERSION="$version" -DVERSION4="$core.$run" \
    -DSTAGE="$(cygpath -w "$OUT_DIR/stage")" \
    -DOUTFILE="$(cygpath -w "$OUT_DIR/$installer")" \
    "$(cygpath -w "$SCRIPT_DIR/installer.nsi")"
(cd "$OUT_DIR" && sha256sum "$installer" > SHA256SUMS)
echo "Built $OUT_DIR/$installer"

if [[ "$dry_run" == --dry-run ]]; then
    exit 0
fi

if [[ "$channel" == stable ]]; then
    gh release create "$tag" "$OUT_DIR/$installer" "$OUT_DIR/SHA256SUMS" \
        --target "$(git rev-parse HEAD)" --title "Sharp $version" --generate-notes --latest
else
    gh release create "$tag" "$OUT_DIR/$installer" "$OUT_DIR/SHA256SUMS" \
        --target "$(git rev-parse HEAD)" --title "Sharp Nightly $version" --generate-notes --prerelease
fi
echo "Published $tag"
