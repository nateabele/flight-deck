#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

# Fresh-launch guard: the UI tests assert the window is present on the primary
# display. RootWindow pins the initial placement with .defaultPosition(.center),
# but SwiftUI only applies a default position when there is NO saved window
# frame; a restored frame from a previous run would win and could re-place the
# window off the primary display (e.g. onto an external monitor at negative X),
# which fails every UI-test assertion.
#
# Delete ONLY the window-geometry keys. This script used to `defaults delete` the
# whole domain, which also destroyed `sessions.snapshot.v1` and `preferences.v1` —
# i.e. every real session, project and preference the user had, on every smoke run.
# That was never needed: isolation is the `-FlightDeckResetState YES` launch
# argument the UI test passes (see TerminalSmokeTests), which makes the app start
# from a fresh slate without touching what is stored — sessions via SessionStore's
# `resetState`, preferences via a nil PreferencesPersisting (see FlightDeckApp).
# Window geometry is the only thing that flag does not cover, because AppKit
# restores it before any of our code runs. So it is the only thing wiped here.
#
# Saved Application State holds no user data (AppKit writes it), so removing that
# directory wholesale is still fine.
for key in \
  "NSWindow Frame main" \
  "NSWindow Frame com_apple_SwiftUI_Settings_window" \
  "NSSplitView Subview Frames main, SidebarNavigationSplitView"
do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done
rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState 2>/dev/null || true

# --- Output discipline ---------------------------------------------------
# xcodebuild is extremely verbose (thousands of compiler-invocation lines).
# Dumping that to stdout when this script is run as a `! ./scripts/smoke.sh`
# command floods and destroys the agent's context window. So: send ALL noisy
# output to a git-ignored log file and surface only a compact summary here.
# To read the full transcript on failure: `cat scripts/.smoke.log`.
LOG="scripts/.smoke.log"
: > "$LOG"

echo "[smoke] building… (full output → $LOG)"
if ! ./scripts/build.sh >>"$LOG" 2>&1; then
  echo "SMOKE FAIL: build failed — see $LOG"
  tail -n 30 "$LOG"
  exit 1
fi

xcodegen generate >>"$LOG" 2>&1

echo "[smoke] running FlightDeckUITests… (full output → $LOG)"
set +e
# -derivedDataPath matches build.sh and test-unit.sh. Without it this invocation used the
# shared default DerivedData (~/Library/Developer/Xcode/DerivedData/FlightDeck-*), while
# build.sh had just built into the local one — so it rebuilt from scratch there and, with a
# second worktree or Xcode using that same directory, raced their build. The observed
# failure was `DVTAssertions: Assertion failed: childPID > 0` immediately after xcodebuild
# logged `Removed stale file .../Debug/FlightDeck.app`: the app it was about to launch had
# been deleted out from under it by the other build.
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  test -only-testing:FlightDeckUITests >>"$LOG" 2>&1
rc=$?
set -e

# Compact summary: per-test pass/fail lines, assertion failures, final banner.
grep -E "Test Case '.*' (passed|failed)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" \
  | tail -n 40 || true

if [ "$rc" -ne 0 ]; then
  echo "SMOKE FAIL (rc=$rc) — full log: $LOG"
  exit "$rc"
fi
echo "SMOKE PASS"
