#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Fresh-launch guard: the UI tests assert the window is present on the primary
# display. RootWindow pins the initial placement with .defaultPosition(.center),
# but SwiftUI only applies a default position when there is NO saved window
# frame; a restored frame from a previous run would win and could re-place the
# window off the primary display (e.g. onto an external monitor at negative X),
# which fails every UI-test assertion. Wipe all persisted state so the centered
# default governs. Saved per-window frames live in ~/Library/Saved Application
# State/, not just Preferences, so wipe all three locations.
defaults delete dev.flightdeck.FlightDeck 2>/dev/null || true
rm -f ~/Library/Preferences/dev.flightdeck.FlightDeck.plist 2>/dev/null || true
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
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
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
