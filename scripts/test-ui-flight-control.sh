#!/usr/bin/env bash
# Runs SwarmUITests against the Flight Control fixture backend (L3-S Task 14).
#
# NOT scripts/smoke.sh, and never looped. It launches Flight Deck (Debug) and takes the
# foreground for a few minutes, so it warns first and honours the same one-run-per-120s throttle
# as smoke.sh. Touches no live state: -FlightDeckResetState gives preferences a nil persistence,
# -FlightDeckFixture redirects sessions/status/transcripts and replaces the login shell with a
# stub agent (no `claude` ever runs), -FlightControlFixtureBackend points am/br at stubs, and
# -FlightDeckDaemonDir keeps the fixture's fd-abduco daemons apart from every real one.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

echo "[flight-control-ui] Flight Deck (Debug) takes the foreground in 10 seconds — stop typing."
osascript -e 'display notification "Flight Deck UI test takes the foreground in 10 s" with title "Flight Control UI test"' >/dev/null 2>&1 || true
sleep 10

for key in "NSWindow Frame main" "NSSplitView Subview Frames main, SidebarNavigationSplitView"; do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done

LOG="scripts/.flight-control-ui.log"
: > "$LOG"
ROOT="$PWD/DerivedData/flight-control-fixture"
cleanup() {
  # The fixture's tabs run under detached daemons that outlive the app; reap them by path.
  pkill -f "$ROOT" 2>/dev/null || true
}
trap cleanup EXIT
python3 scripts/make-flight-control-fixture.py "$ROOT/live" >>"$LOG" 2>&1
python3 scripts/make-flight-control-fixture.py "$ROOT/seeded" --seeded >>"$LOG" 2>&1
xcodegen generate >>"$LOG" 2>&1

RESULTS="$PWD/DerivedData/flight-control-ui.xcresult"
rm -rf "$RESULTS"
echo "[flight-control-ui] running SwarmUITests… (full output → $LOG)"
set +e
TEST_RUNNER_FLIGHT_CONTROL_FIXTURE="$ROOT/live" TEST_RUNNER_FLIGHT_CONTROL_SEEDED="$ROOT/seeded" \
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
  -derivedDataPath DerivedData -resultBundlePath "$RESULTS" \
  test -only-testing:FlightDeckUITests/SwarmUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true

OUT="$PWD/DerivedData/flight-control-ui"
rm -rf "$OUT"; mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULTS" --output-path "$OUT" >/dev/null 2>&1 || true
echo "[flight-control-ui] screenshots → $OUT ; stub log → $ROOT/live/stub.log"

if [ "$rc" -ne 0 ]; then
  echo "FLIGHT CONTROL UI FAIL (rc=$rc) — $LOG"
  exit "$rc"
fi
echo "FLIGHT CONTROL UI PASS"
