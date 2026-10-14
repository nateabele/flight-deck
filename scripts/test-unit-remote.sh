#!/usr/bin/env bash
# The unit suite, run on the dedicated UI-test Mac instead of this one. test-unit.sh runs this
# unless FD_TEST_LOCAL=1, and takes the same knobs and prints the same summary:
#
#   FD_TEST_FILTER=ClassA,ClassB/testX  only these (default: the whole sharded suite)
#   FD_TEST_SHARDS=N                    parallel xctest processes for a full run
#   FD_SKIP_BUILD=1                     reuse the last build-for-testing here
#   FD_SKIP_MENUBAR=1                   leave out the menu-bar lane of a full run
#
# Why another machine: the suite is not headless. *LiveTests classes open real windows (a
# ParkedWindow at -10000 plus orderFrontRegardless), NSHostingView renders run, and the menu-bar
# lane puts up a SwiftUI app. Here they take windows and focus on the developer's screen.
#
# Shape: build-for-testing HERE (this Mac has the toolchain, the vendored artifacts and the
# signing team), rsync the checkout and its products to the SAME absolute path on the UI-test Mac,
# and run `test-unit.sh` there with FD_TEST_LOCAL=1 FD_SKIP_BUILD=1. What "the unit bundle needs
# this Mac's state" (patch-xctestrun.py) turned out to be:
#   - the bundle bakes in this checkout's absolute path: tests locate fixtures, shell scripts,
#     docs and Sources through #filePath, read vendor/fd-abduco-artifacts/fd-abduco and the
#     scripts through the working directory, and the test bundle's rpath names its own
#     PackageFrameworks directory. Same absolute path remotely (both users are `me`) satisfies
#     all of them with no rewriting, and keeps each worktree's remote copy separate for free.
#   - XCTest. The UI-test Mac's Xcode is older, so this Xcode's xctest binary and test frameworks
#     travel as ~/flightdeck-uitests/xctest26 and FD_XCTEST_SHIM points test-unit.sh at them.
#   - the menu-bar harness is compiled here (the older swiftc cannot read this Xcode's modules)
#     and only run there.
# Tools on PATH (git, rg, python3) are the UI-test Mac's own and are all it needs; scripts/local.env
# is NOT shipped, and is not needed there.
#
#   FD_UITEST_HOST    ssh destination, required
#   FD_UITEST_SSH_KEY identity file (default: ssh's own defaults and ~/.ssh/config)
# Both are read from the environment or from scripts/local.env (git-ignored; copy
# scripts/local.env.example). No default host is committed: this repo is public.
#
# Holds the same remote lock as smoke-remote.sh, so a unit run never overlaps an XCUITest run (or
# another worktree's unit run), but not its run-rate throttle: this is the TDD loop.
# Never falls back to running here: an unreachable host is a failure that says so.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

source scripts/lib-local-env.sh
fd_load_local_env
HOST=${FD_UITEST_HOST:-}
KEY=${FD_UITEST_SSH_KEY:-}
if [ -z "$HOST" ]; then
  echo "UNIT FAIL: no UI-test host configured."
  echo "           cp scripts/local.env.example scripts/local.env and set FD_UITEST_HOST,"
  echo "           or FD_TEST_LOCAL=1 to run on THIS Mac (it opens windows on this screen)."
  exit 2
fi
REMOTE_DIR=flightdeck-uitests   # relative to the remote home; smoke-remote.sh's lock lives here too
SHIM="$REMOTE_DIR/xctest26"
ROOT="$PWD"                     # the same absolute path on the remote
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30)
[ -n "$KEY" ] && SSH_OPTS+=(-o IdentitiesOnly=yes -i "$KEY")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"
LOG="scripts/.test-unit-remote.log"
XCTEST_SRC="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"

# The remote login shell is fish, so every remote command is bash fed on stdin.
remote() { ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$@"; }

: > "$LOG"
if ! ssh "${SSH_OPTS[@]}" "$HOST" true >>"$LOG" 2>&1; then
  echo "UNIT FAIL: UI-test host $HOST is unreachable (ssh, 5s timeout)."
  echo "           Set FD_UITEST_HOST to another host, or FD_TEST_LOCAL=1 to run on THIS Mac"
  echo "           (it opens windows on this screen)."
  exit 2
fi

# --- Build here ------------------------------------------------------------
if [ -z "${FD_SKIP_BUILD:-}" ]; then
  echo "[unit] building… (full output → $LOG)"
  if ! { xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
      -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData \
      build-for-testing; } >>"$LOG" 2>&1; then
    echo "UNIT FAIL: build failed — see $LOG"
    tail -n 30 "$LOG"
    exit 1
  fi
fi
PRODUCTS=DerivedData/Build/Products/Debug
[ -f "$PRODUCTS/Flight Deck.app/Contents/MacOS/Flight Deck.debug.dylib" ] \
  || { echo "UNIT FAIL: no build at $PRODUCTS (run without FD_SKIP_BUILD=1)"; exit 1; }
# Compile the menu-bar harness here; the remote only runs it (see the header).
if [ -z "${FD_TEST_FILTER:-}" ] && [ -z "${FD_SKIP_MENUBAR:-}" ]; then
  if ! FD_SKIP_BUILD=1 FD_MENUBAR_BUILD_ONLY=1 ./scripts/test-menu-bar.sh >>"$LOG" 2>&1; then
    echo "UNIT FAIL: menu-bar harness did not compile — see $LOG and DerivedData/menubar-harness/build.log"
    exit 1
  fi
fi

# --- The remote lock (same as smoke-remote.sh's, minus the throttle) -------
TOKEN="unit-$(hostname -s)-$$-$(date +%s)"
LOCKED=0

acquire_lock() {
  remote "$REMOTE_DIR" "$TOKEN" <<'REMOTE'
dir=$1 token=$2
mkdir -p "$dir"; cd "$dir"
waited=0
until mkdir .lock 2>/dev/null; do
  if [ -n "$(find .lock -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    echo "breaking stale lock held by $(cat .lock/owner 2>/dev/null)" >&2
    rm -rf .lock; continue
  fi
  if [ "$waited" -eq 0 ]; then echo "[unit] UI-test Mac busy ($(cat .lock/owner 2>/dev/null)); waiting up to 20 min…" >&2; fi
  if [ "$waited" -ge 1200 ]; then echo "error: UI-test Mac still busy after 20 min" >&2; exit 3; fi
  sleep 10; waited=$((waited + 10))
done
echo "$token" > .lock/owner
REMOTE
}

# Reaps what the run leaves behind, then releases the lock. Runs on every exit, including ^C.
# Same reasoning as smoke-remote.sh: tests that start sessions leave detached `fd-abduco` daemons
# (children of launchd) in the Debug socket root, each with a shell inside. Agents get SIGTERM
# first, then the daemons. Only the Debug root /tmp/flight-deck-debug-<uid> is touched; the
# release root /tmp/flight-deck-<uid> holds the UI-test Mac's own real sessions.
cleanup() {
  local rc=$?
  set +e
  if [ "$LOCKED" -eq 1 ]; then
    remote "$REMOTE_DIR" "$TOKEN" "$ROOT" <<'REMOTE' >>"$LOG" 2>&1
dir=$1 token=$2 root=$3
sock=/tmp/flight-deck-debug-$(id -u)
# An aborted run leaves its test-unit.sh and xctest going; under the lock they can only be ours.
pkill -TERM -f "$root/scripts/test-unit.sh" 2>/dev/null
pkill -TERM -f "xctest .*$root/DerivedData/Build/Products/" 2>/dev/null
pkill -TERM -f "$root/DerivedData/menubar-harness/MenuBarHarness" 2>/dev/null
sleep 1
daemons=$(pgrep -f "$sock/fd-abduco -c" | tr '\n' ' ')
descendants=$(ps -axo pid=,ppid= | awk -v roots="$daemons" '
  BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) keep[r[i]] = 1 }
  { parent[$1] = $2; pids[NR] = $1 }
  END {
    for (changed = 1; changed; ) { changed = 0
      for (i in pids) { p = pids[i]; if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; out[p] = 1; changed = 1 } } }
    for (p in out) printf "%s ", p }')
orphans=$(pgrep -f "$root/DerivedData/Build/Products/|$root/DerivedData/menubar-harness/|$root/vendor/fd-abduco-artifacts/" | tr '\n' ' ')
echo "[reap] daemons: ${daemons:-none}; descendants: ${descendants:-none}; orphans: ${orphans:-none}"
if [ -n "$descendants$orphans" ]; then kill -TERM $descendants $orphans 2>/dev/null; sleep 2; fi
if [ -n "$daemons" ]; then kill -TERM $daemons 2>/dev/null; sleep 1; fi
left=$(pgrep -f "$sock/fd-abduco -c|$root/DerivedData/Build/Products/|$root/DerivedData/menubar-harness/" | tr '\n' ' ')
echo "[reap] survivors: ${left:-none}"
[ -z "$left" ] && rm -f "$sock/fd-abduco" && rmdir "$sock" 2>/dev/null
cd "$dir" && [ "$(cat .lock/owner 2>/dev/null)" = "$token" ] && rm -rf .lock
exit 0
REMOTE
    if grep -q 'survivors: [0-9]' "$LOG"; then
      echo "[unit] warning: processes survived the reap on $HOST — see $LOG"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "[unit] locking the UI-test Mac…"
acquire_lock 2>&1 | tee -a "$LOG" >&2 || true
# `tee` hides the remote's exit status, so the lock is confirmed by reading it back.
if [ "$(remote "$REMOTE_DIR" <<<'cat "$1/.lock/owner" 2>/dev/null')" != "$TOKEN" ]; then
  echo "UNIT FAIL: did not get the UI-test lock on $HOST (see above)"
  exit 2
fi
LOCKED=1

# --- Ship ------------------------------------------------------------------
echo "[unit] syncing to the UI-test Mac (${ROOT})…"
ship() {  # rsync args…: any failure ends the run
  if ! rsync -a -e "$RSYNC_SSH" "$@" >>"$LOG" 2>&1; then
    echo "UNIT FAIL: rsync to $HOST failed — see $LOG"
    exit 1
  fi
}
remote "$ROOT" <<<'mkdir -p "$1"'
# The checkout: sources, tests, fixtures, scripts, docs. DerivedData goes separately; .git and
# the other worktrees are not tests' business; the vendor artifacts are symlinks in a worktree
# and travel as real directories below; local.env holds the host and is not needed there.
ship --delete \
  --exclude '/.git' --exclude '/.claude' --exclude '/.superpowers' --exclude '/DerivedData' \
  --exclude '/FlightDeck.xcodeproj' --exclude '/vendor/*-artifacts' --exclude '/scripts/local.env' \
  --exclude '.DS_Store' \
  ./ "$HOST:$ROOT/"
# Only fd-abduco is read at run time; ghostty and boringssl are link inputs, already in the build.
ship -L vendor/fd-abduco-artifacts "$HOST:$ROOT/vendor/"
# Products. Object files, static archives, module interfaces and headers are build inputs only
# (most of the bytes, none of the test); --delete keeps a renamed bundle from leaving a twin.
remote "$ROOT/$PRODUCTS" <<<'mkdir -p "$1"'
ship --delete \
  --exclude '*.a' --exclude '*.o' --exclude '*.swiftmodule' --exclude 'include' \
  "$PRODUCTS/" "$HOST:$ROOT/$PRODUCTS/"
if [ -z "${FD_TEST_FILTER:-}" ] && [ -z "${FD_SKIP_MENUBAR:-}" ]; then
  remote "$ROOT/DerivedData/menubar-harness" <<<'mkdir -p "$1"'
  ship DerivedData/menubar-harness/MenuBarHarness "$HOST:$ROOT/DerivedData/menubar-harness/"
fi
[ -f DerivedData/fd-test-class-timings.tsv ] \
  && ship DerivedData/fd-test-class-timings.tsv "$HOST:$ROOT/DerivedData/"

# This Xcode's xctest and XCTest, for a remote Xcode that may be older. Stamped with this Xcode's
# build number and wiped when it changes (the same scheme as smoke-remote.sh's shim). The binary
# sits at the top: its rpaths only matter when the frameworks are not found through
# DYLD_FRAMEWORK_PATH, which test-unit.sh points at this directory.
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ { print $3 }')
if [ "$(remote "$SHIM" <<<'cat "$1/.xcode-build" 2>/dev/null')" != "$XCODE_BUILD" ]; then
  echo "[unit] shipping this Xcode's xctest and test frameworks ($XCODE_BUILD)…"
  remote "$SHIM" <<<'rm -rf "$1" && mkdir -p "$1"'
  ship "$XCTEST_SRC"/Library/Frameworks/*.framework \
       "$XCTEST_SRC"/Library/PrivateFrameworks/*.framework \
       "$XCTEST_SRC"/usr/lib/*.dylib \
       "$XCTEST_SRC"/Library/Xcode/Agents/xctest \
       "$HOST:$SHIM/"
  remote "$SHIM" "$XCODE_BUILD" <<<'echo "$2" > "$1/.xcode-build"'
fi

# --- Run -------------------------------------------------------------------
# The knobs travel as NAME=VALUE arguments, never spliced into a command string.
ENVARGS=(FD_TEST_LOCAL=1 FD_SKIP_BUILD=1 FD_MENUBAR_PREBUILT=1)
for name in FD_TEST_FILTER FD_TEST_SHARDS FD_SKIP_MENUBAR; do
  [ -n "${!name:-}" ] && ENVARGS+=("$name=${!name}")
done
echo "[unit] running${FD_TEST_FILTER:+ $FD_TEST_FILTER} on the UI-test Mac…"
set +e
# Stdout is test-unit.sh's own compact summary (or xctest's output for a filtered run), the same
# as a local run; the per-shard logs come back below.
remote "$ROOT" "$SHIM" "${ENVARGS[@]}" <<'REMOTE' 2>&1 | tee -a "$LOG"
cd "$1"; shim="$HOME/$2"; shift 2
env FD_XCTEST_SHIM="$shim" "$@" ./scripts/test-unit.sh
REMOTE
rc=${PIPESTATUS[0]}
set -e

# The shard logs (and the menu-bar lane's) and the refreshed per-class timings come back, so the
# banner's "logs in DerivedData/fd-test-shards" points at something here.
rsync -a -e "$RSYNC_SSH" "$HOST:$ROOT/DerivedData/fd-test-shards" "$HOST:$ROOT/DerivedData/fd-test-class-timings.tsv" \
  DerivedData/ >>"$LOG" 2>&1 || true
exit "$rc"
