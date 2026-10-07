#!/usr/bin/env bash
# The UI suite, run on the dedicated UI-test Mac instead of this one. smoke.sh runs this unless
# FD_SMOKE_LOCAL=1.
#
# Why another machine: an XCUITest run seizes the foreground for minutes and fires key events
# into whatever holds focus, so a run here took over the developer's screen and their typing
# showed up as phantom test failures. The UI-test Mac has nobody at it.
#
# Shape: build-for-testing HERE (this Mac has the toolchain, the vendored artifacts and the
# signing team), rsync the products to the UI-test Mac, and run `xcodebuild
# test-without-building` there. The remote Xcode can be older than this one, so this Xcode's
# test frameworks travel with the products (`xctest26/`) and scripts/patch-xctestrun.py points
# the runner at them — see that script for the failure each change prevents.
#
#   FD_UITEST_HOST    ssh destination, required
#   FD_UITEST_SSH_KEY identity file (default: ssh's own defaults and ~/.ssh/config)
# Both are read from the environment or from scripts/local.env (git-ignored; copy
# scripts/local.env.example). No default host is committed: this repo is public.
#   TEST_RUNNER_*     forwarded into the runner, prefix stripped, as `xcodebuild test` does
#   FLIGHTDECK_TEST_THROTTLE  minimum seconds between runs on the UI-test Mac (default 120)
#   FD_UITEST_ONLY    space-separated -only-testing: identifiers (default FlightDeckUITests), so
#                     any UI-test script can run its own selection here instead of on this
#                     Mac's screen, e.g. FD_UITEST_ONLY="FlightDeckUITests/FlightControlUITests"
#                     A selection whose every case skipped (a TEST_RUNNER_* gate unset) ends
#                     "SMOKE SKIPPED" with exit status 5, never "SMOKE PASS".
#
# Never falls back to running here: an unreachable host is a failure that says so.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

source scripts/lib-local-env.sh
fd_load_local_env
HOST=${FD_UITEST_HOST:-}
KEY=${FD_UITEST_SSH_KEY:-}
if [ -z "$HOST" ]; then
  echo "SMOKE FAIL: no UI-test host configured."
  echo "            cp scripts/local.env.example scripts/local.env and set FD_UITEST_HOST,"
  echo "            or FD_SMOKE_LOCAL=1 to run on THIS Mac (it takes over the screen)."
  exit 2
fi
THROTTLE=${FLIGHTDECK_TEST_THROTTLE:-120}
# Relative to the remote home. The products path MUST contain `/DerivedData/`:
# `assertFlightDeckIsFrontmost` tells the app under test from an installed Flight Deck by that
# string in its bundle path, and fails every click-driven group without it.
REMOTE_DIR=flightdeck-uitests
REMOTE_PRODUCTS=$REMOTE_DIR/DerivedData/Build/Products
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30)
# IdentitiesOnly with an explicit key: an agent holding many keys otherwise exhausts the
# server's auth attempts ("Too many authentication failures") before offering the right one.
[ -n "$KEY" ] && SSH_OPTS+=(-o IdentitiesOnly=yes -i "$KEY")
LOG="scripts/.smoke.log"
read -r -a ONLY <<<"${FD_UITEST_ONLY:-FlightDeckUITests}"
ONLY_ARGS=()
for t in "${ONLY[@]}"; do ONLY_ARGS+=("-only-testing:$t"); done
OUT="DerivedData/smoke-remote"
XCTEST_SRC="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"

# The remote login shell is fish, so every remote command is bash fed on stdin, never a
# command string fish would have to parse.
remote() { ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$@"; }

# Same output discipline as smoke.sh: everything noisy goes to $LOG, never stdout, because a
# full xcodebuild transcript floods an agent's context window.
: > "$LOG"
mkdir -p "$OUT"

if ! ssh "${SSH_OPTS[@]}" "$HOST" true >>"$LOG" 2>&1; then
  echo "SMOKE FAIL: UI-test host $HOST is unreachable (ssh, 5s timeout)."
  echo "            Set FD_UITEST_HOST to another host, or FD_SMOKE_LOCAL=1 to run on THIS Mac"
  echo "            (it takes over the screen for several minutes)."
  exit 2
fi

# --- The remote lock ------------------------------------------------------
# Several sessions on this Mac share one UI-test Mac. Two runs at once would rsync products
# over each other mid-run and fight over the one foreground, so a run holds a lock on the
# remote for its whole length. `mkdir` is the atomic test-and-set. A lock older than 45
# minutes is a run that died without its trap (a full first build plus a run is well under
# that) and is broken rather than wedging every later run.
TOKEN="$(hostname -s)-$$-$(date +%s)"
LOCKED=0

acquire_lock() {
  remote "$REMOTE_DIR" "$TOKEN" "$THROTTLE" <<'REMOTE'
dir=$1 token=$2 throttle=$3
mkdir -p "$dir"; cd "$dir"
waited=0
until mkdir .lock 2>/dev/null; do
  if [ -n "$(find .lock -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    echo "breaking stale lock held by $(cat .lock/owner 2>/dev/null)" >&2
    rm -rf .lock; continue
  fi
  if [ "$waited" -eq 0 ]; then echo "[smoke] UI-test Mac busy ($(cat .lock/owner 2>/dev/null)); waiting up to 20 min…" >&2; fi
  if [ "$waited" -ge 1200 ]; then echo "error: UI-test Mac still busy after 20 min" >&2; exit 3; fi
  sleep 10; waited=$((waited + 10))
done
echo "$token" > .lock/owner
# smoke.sh's run-rate cap, enforced where the runs happen so every session on every Mac shares
# one window. The stamp is written BEFORE the run, so a crashed run still counts.
if [ "$throttle" -gt 0 ] && [ -f .last-run ]; then
  remaining=$(( throttle - ($(date +%s) - $(cat .last-run)) ))
  if [ "$remaining" -gt 0 ]; then
    rm -rf .lock
    echo "error: a UI run started on this host less than ${throttle}s ago. Wait ${remaining}s." >&2
    echo "       Deliberate override: FLIGHTDECK_TEST_THROTTLE=0" >&2
    exit 2
  fi
fi
date +%s > .last-run
REMOTE
}

# Reaps what a run leaves behind, then releases the lock. Runs on every exit, including ^C.
#
# A UI run leaves detached `fd-abduco` daemons in the Debug socket root, each with a shell and
# often a real `claude` inside: they are children of launchd, not of the app, so the app's exit
# does not take them. Left alone they pile up four per run. Agents get SIGTERM first so each
# closes its transcript cleanly, then the daemons, so each unlinks its socket and pid sidecar
# (AGENT-OPERATIONS.md §2). Only the Debug root is touched: the release root
# /tmp/flight-deck-<uid> holds the UI-test Mac's own real sessions.
cleanup() {
  local rc=$?
  set +e
  if [ "$LOCKED" -eq 1 ]; then
    remote "$REMOTE_DIR" "$TOKEN" <<'REMOTE' >>"$LOG" 2>&1
dir=$1 token=$2
root=/tmp/flight-deck-debug-$(id -u)
# A run aborted from this side leaves its xcodebuild going; under the lock it can only be ours.
pkill -TERM -f "xcodebuild test-without-building .*smoke-remote.xctestrun" 2>/dev/null
daemons=$(pgrep -f "$root/fd-abduco -c" | tr '\n' ' ')
# Every descendant of a Debug daemon, plus any agent the products launched that was already
# orphaned from its daemon.
descendants=$(ps -axo pid=,ppid= | awk -v roots="$daemons" '
  BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) keep[r[i]] = 1 }
  { parent[$1] = $2; pids[NR] = $1 }
  END {
    for (changed = 1; changed; ) { changed = 0
      for (i in pids) { p = pids[i]; if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; out[p] = 1; changed = 1 } } }
    for (p in out) printf "%s ", p }')
orphans=$(pgrep -f "/$dir/DerivedData/Build/Products/" | tr '\n' ' ')
echo "[reap] daemons: ${daemons:-none}; descendants: ${descendants:-none}; orphans: ${orphans:-none}"
if [ -n "$descendants$orphans" ]; then kill -TERM $descendants $orphans 2>/dev/null; sleep 2; fi
if [ -n "$daemons" ]; then kill -TERM $daemons 2>/dev/null; sleep 1; fi
left=$(pgrep -f "$root/fd-abduco -c|/$dir/DerivedData/Build/Products/" | tr '\n' ' ')
echo "[reap] survivors: ${left:-none}"
[ -z "$left" ] && rm -f "$root/fd-abduco" && rmdir "$root" 2>/dev/null
cd "$dir" && [ "$(cat .lock/owner 2>/dev/null)" = "$token" ] && rm -rf .lock
exit 0
REMOTE
    if grep -q 'survivors: [0-9]' "$LOG"; then
      echo "[smoke] warning: processes survived the reap on $HOST — see $LOG"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "[smoke] locking ${HOST}…"
acquire_lock 2>&1 | tee -a "$LOG" >&2 || true
# `tee` hides the remote's exit status, so the lock is confirmed by reading it back.
if [ "$(remote "$REMOTE_DIR" <<<'cat "$1/.lock/owner" 2>/dev/null')" != "$TOKEN" ]; then
  echo "SMOKE FAIL: did not get the UI-test lock on $HOST (see above)"
  exit 2
fi
LOCKED=1

echo "[smoke] building for testing… (full output → $LOG)"
if ! { xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData \
    build-for-testing "${ONLY_ARGS[@]}"; } >>"$LOG" 2>&1; then
  echo "SMOKE FAIL: build failed — see $LOG"
  tail -n 30 "$LOG"
  exit 1
fi

# Newest xctestrun, never our own patched copy. Its name tracks the SDK version, so a glob.
XCTESTRUN=$(ls -t DerivedData/Build/Products/*.xctestrun | grep -v smoke-remote | head -n 1)
FORWARD=()
while IFS='=' read -r name value; do
  [ -n "$name" ] && FORWARD+=("${name#TEST_RUNNER_}=$value")
done < <(env | grep '^TEST_RUNNER_' || true)
python3 scripts/patch-xctestrun.py "$XCTESTRUN" "$OUT/smoke-remote.xctestrun" ${FORWARD[@]+"${FORWARD[@]}"}

echo "[smoke] syncing products to ${HOST}…"
# Object files, static archives, module interfaces and headers are build inputs only — they
# are most of the bytes and none of the test. `--delete` keeps a renamed bundle from leaving a
# stale twin behind; xctest26/ is excluded, so --delete leaves it alone.
RSYNC_SSH="ssh ${SSH_OPTS[*]}"
if ! rsync -a --delete -e "$RSYNC_SSH" \
    --exclude '*.a' --exclude '*.o' --exclude '*.swiftmodule' --exclude 'include' \
    --exclude 'xctest26' --exclude '*.xctestrun' \
    DerivedData/Build/Products/ "$HOST:$REMOTE_PRODUCTS/" >>"$LOG" 2>&1; then
  echo "SMOKE FAIL: rsync of products to $HOST failed — see $LOG"
  exit 1
fi

# This Xcode's XCTest, for a remote Xcode that may be older (see patch-xctestrun.py). Stamped
# with this Xcode's build number and wiped when it changes, so an Xcode upgrade here re-ships
# the shim instead of leaving a mix of two Xcodes' frameworks.
# The bare build number: the remote shell splits arguments on spaces.
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ { print $3 }')
SHIM="$REMOTE_PRODUCTS/xctest26"
if [ "$(remote "$SHIM" <<<'cat "$1/.xcode-build" 2>/dev/null')" != "$XCODE_BUILD" ]; then
  echo "[smoke] shipping this Xcode's test frameworks ($XCODE_BUILD)…"
  remote "$SHIM" <<<'rm -rf "$1" && mkdir -p "$1"'
  if ! rsync -a -e "$RSYNC_SSH" \
      "$XCTEST_SRC"/Library/Frameworks/*.framework \
      "$XCTEST_SRC"/Library/PrivateFrameworks/*.framework \
      "$XCTEST_SRC"/usr/lib/*.dylib \
      "$HOST:$SHIM/" >>"$LOG" 2>&1; then
    echo "SMOKE FAIL: rsync of the xctest26 shim to $HOST failed — see $LOG"
    exit 1
  fi
  remote "$SHIM" "$XCODE_BUILD" <<<'echo "$2" > "$1/.xcode-build"'
fi
rsync -a -e "$RSYNC_SSH" "$OUT/smoke-remote.xctestrun" "$HOST:$REMOTE_PRODUCTS/" >>"$LOG" 2>&1

echo "[smoke] running ${ONLY[*]} on ${HOST}… (full output → $LOG)"
set +e
remote "$REMOTE_DIR" "${ONLY_ARGS[@]}" <<'REMOTE' >>"$LOG" 2>&1
cd "$1"; shift
# The same fresh-launch guard as smoke.sh, for the same reason: a saved window frame wins over
# `.defaultPosition(.center)` and can park the window off the primary display. Window geometry
# ONLY — never `defaults delete` the domain, which holds this Mac's real preferences.
for key in \
  "NSWindow Frame main" \
  "NSWindow Frame com_apple_SwiftUI_Settings_window" \
  "NSSplitView Subview Frames main, SidebarNavigationSplitView"
do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done
rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState
rm -rf run.xcresult
xcodebuild test-without-building \
  -xctestrun DerivedData/Build/Products/smoke-remote.xctestrun \
  -destination platform=macOS "$@" \
  -resultBundlePath run.xcresult > run.log 2>&1
rc=$?
echo "[remote] xcodebuild rc=$rc"
exit $rc
REMOTE
rc=$?
set -e

rm -rf "$OUT/run.xcresult"
rsync -a -e "$RSYNC_SSH" "$HOST:$REMOTE_DIR/run.log" "$HOST:$REMOTE_DIR/run.xcresult" "$OUT/" >>"$LOG" 2>&1 \
  || echo "[smoke] warning: could not copy the log/xcresult back from $HOST"
cat "$OUT/run.log" >>"$LOG" 2>/dev/null || true

# Compact summary, identical to smoke.sh's: per-test lines, assertion failures, final banner.
grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$OUT/run.log" \
  | tail -n 40 || true

if [ "$rc" -ne 0 ]; then
  echo "SMOKE FAIL (rc=$rc) — full log: $LOG, result bundle: $OUT/run.xcresult"
  exit "$rc"
fi
# PASS, or SKIPPED (exit 5) when named classes skipped every case — see lib-smoke-verdict.sh.
source scripts/lib-smoke-verdict.sh
smoke_verdict "$OUT/run.log" "${ONLY[@]}"
