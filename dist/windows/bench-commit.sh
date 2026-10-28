#!/usr/bin/env bash
# Builds the latest commit into zig-out-bench (so a running Sharp in
# zig-out is never touched) and runs frame_benchmark.py against the saved
# baseline. Results go to .git/sharp-bench.log; a broken budget or a
# regression also shows a Windows notification, which takes no focus.
# Commits arriving during a run are measured once, by one more run.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

readonly lock=.git/sharp-bench.lock
readonly pending=.git/sharp-bench.pending
readonly log=.git/sharp-bench.log
readonly zig=/c/dev/tools/zig-x86_64-windows-0.17.0/zig.exe

notify_broken() {
  local commit=$1
  powershell.exe -NoProfile -Command "
    Add-Type -AssemblyName System.Windows.Forms
    \$n = New-Object System.Windows.Forms.NotifyIcon
    \$n.Icon = [System.Drawing.SystemIcons]::Warning
    \$n.Visible = \$true
    \$n.ShowBalloonTip(10000, 'Sharp', 'Commit $commit broke the performance budget. See .git/sharp-bench.log', 'Warning')
    Start-Sleep -Seconds 11
    \$n.Dispose()" >/dev/null 2>&1
}

measure() {
  local commit status
  commit=$(git rev-parse --short HEAD)
  {
    echo "=== $(date '+%Y-%m-%d %H:%M') $commit $(git log -1 --format=%s)"
    if ! "$zig" build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p zig-out-bench 2>&1 | grep -E 'error' ; then
      python dist/windows/frame_benchmark.py zig-out-bench/bin/sharp.exe "$commit" --baseline dist/windows/frame_baseline.json 2>&1
      status=$?
    else
      echo "build failed"
      status=1
    fi
    echo
  } >>"$log"
  if [ "${status:-1}" -ne 0 ]; then
    notify_broken "$commit"
  fi
}

# One run at a time; later commits leave a note for the running one.
if ! mkdir "$lock" 2>/dev/null; then
  touch "$pending"
  exit 0
fi
trap 'rmdir "$lock"' EXIT

while :; do
  rm -f "$pending"
  measure
  [ -e "$pending" ] || break
done
