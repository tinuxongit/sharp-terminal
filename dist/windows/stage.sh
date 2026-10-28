#!/bin/bash
# Copy a build's payload (payload.txt) into the layout Sharp runs from:
# bin/ files beside sharp.exe, share/ as it is. Fails on anything missing.
#
# Usage: stage.sh <build prefix, e.g. zig-out> <destination folder>
set -euo pipefail

prefix="$1"
dest="$2"
list="$(dirname "$0")/payload.txt"

rm -rf "$dest"
mkdir -p "$dest"
while IFS= read -r entry; do
    entry="${entry%$'\r'}"
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    src="$prefix/$entry"
    target="$dest/${entry#bin/}"
    if [[ "$entry" == */ ]]; then
        [[ -d "$src" ]] || { echo "stage.sh: missing $src" >&2; exit 1; }
        mkdir -p "$target"
        cp -r "$src." "$target"
    else
        [[ -f "$src" ]] || { echo "stage.sh: missing $src" >&2; exit 1; }
        mkdir -p "$(dirname "$target")"
        cp "$src" "$target"
    fi
done < "$list"
