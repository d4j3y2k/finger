#!/bin/bash
# Installs Finger as an always-available background utility: builds it, quits
# the running copy, swaps the new build into /Applications, turns on Open at
# Login and starts it in the background. Run it again after any change.
#
# Overrides, so it can be tried against a temporary folder:
#   FINGER_APP_DEST       where the app goes (default /Applications/Finger.app)
#   FINGER_LAUNCH_AGENTS  the LaunchAgents folder (default ~/Library/LaunchAgents)
#   FINGER_LAUNCHCTL      the launchctl to use (default /bin/launchctl)
#   FINGER_LAUNCH         the command that starts it; 0 skips it
#                         (default: open -a "$FINGER_APP_DEST" --args --background)
#   FINGER_QUIT=0         leave a running Finger alone
#   FINGER_BUNDLE_ID      which running app to quit (default com.d4j3y2k.Finger)
#   FINGER_SKIP_BUILD=1   install the existing build/Finger.app
set -euo pipefail
# realpath gives the folder's on-disk capitalization, as scripts/build.sh expects.
cd "$(realpath "$(dirname "$0")/..")"

dest="${FINGER_APP_DEST:-/Applications/Finger.app}"
bundle_id="${FINGER_BUNDLE_ID:-com.d4j3y2k.Finger}"
export FINGER_LAUNCH_AGENTS="${FINGER_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
export FINGER_LAUNCHCTL="${FINGER_LAUNCHCTL:-/bin/launchctl}"
step() { printf '• %s\n' "$*"; }

# 1. Build.
if [[ "${FINGER_SKIP_BUILD:-0}" == 1 ]]; then
  step "Using the existing build/Finger.app"
else
  log="build/install-build.log"
  mkdir -p build
  step "Building (log: $log)"
  if ! ./scripts/build.sh >"$log" 2>&1; then
    tail -30 "$log" >&2
    echo "The build failed; nothing was installed." >&2
    exit 1
  fi
fi
[[ -x build/Finger.app/Contents/MacOS/Finger ]] || { echo "build/Finger.app is missing." >&2; exit 1; }

# 2. Quit the running Finger the way the Quit menu item would: through
# NSRunningApplication.terminate(), from JXA's ObjC bridge. No Apple events
# are sent to other apps. Anything still running after 5 s gets SIGTERM.
if [[ "${FINGER_QUIT:-1}" == 0 ]]; then
  step "Leaving any running Finger alone (FINGER_QUIT=0)"
else
  pids="$(osascript -l JavaScript - "$bundle_id" <<'JS'
function run(argv) {
  ObjC.import('AppKit');
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
  const pids = [];
  for (let i = 0; i < apps.count; i++) {
    const app = apps.objectAtIndex(i);
    pids.push(app.processIdentifier);
    app.terminate;
  }
  return pids.join(' ');
}
JS
)"
  if [[ -z "$pids" ]]; then
    step "No running Finger to quit"
  else
    step "Asked Finger to quit (pid $pids)"
    for _ in $(seq 50); do
      alive=""
      for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
      [[ -z "$alive" ]] && break
      sleep 0.1
    done
    if [[ -n "$alive" ]]; then
      step "Still running after 5 s; sending SIGTERM to$alive"
      kill -TERM $alive 2>/dev/null || true
      sleep 1
    fi
  fi
fi

# 3. Stage next to the destination and swap it in atomically, so a failure
# never leaves a half-copied app behind.
parent="$(dirname "$dest")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.Finger-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto build/Finger.app "$stage/Finger.app"
codesign --verify --deep --strict "$stage/Finger.app"
if [[ -e "$dest" ]]; then
  python3 - "$stage/Finger.app" "$dest" <<'PYTHON'
import ctypes, os, sys
src, dst = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(os.fsencode(src), os.fsencode(dst), 0x2) != 0:  # RENAME_SWAP
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), dst)
PYTHON
  step "Replaced $dest"
else
  mv "$stage/Finger.app" "$dest"
  step "Installed $dest"
fi
rm -rf "$stage"
trap - EXIT

# 4. Open at Login: a LaunchAgent that runs the installed app with
# --background. It loads at the next login; step 5 starts Finger now.
"$dest/Contents/MacOS/Finger" --login-item on --no-load | sed 's/^/• /'

# 5. Start it in the background: no window, the menu bar item and ⌃Space.
if [[ "${FINGER_LAUNCH-}" == 0 ]]; then
  step "Not starting Finger (FINGER_LAUNCH=0)"
else
  if [[ -n "${FINGER_LAUNCH-}" ]]; then
    bash -c "$FINGER_LAUNCH"
  else
    open -a "$dest" --args --background
  fi
  started=""
  for _ in $(seq 50); do
    started="$(pgrep -f "^$dest/Contents/MacOS/Finger" | head -1 || true)"
    [[ -n "$started" ]] && break
    sleep 0.1
  done
  if [[ -n "$started" ]]; then
    step "Started Finger in the background (pid $started). Press ⌃Space, or use the menu bar item."
  else
    step "Asked macOS to start Finger; it hasn't appeared yet."
  fi
fi
