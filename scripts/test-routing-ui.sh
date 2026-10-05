#!/usr/bin/env bash
# Runs RoutingUITests ONLY: Settings → Flight Control against the routing fixture.
#
# Not part of smoke.sh, and that is deliberate — smoke.sh runs the whole UI bundle, and these
# tests skip there unless TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1. Like every UI test they seize the
# foreground and read keystrokes, so: one run per 120 s (throttle.sh), a 10 s warning first, and
# never in a loop. Screenshots land in DerivedData/routing-ui-shots.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

LOG="scripts/.routing-ui.log"
RESULT="DerivedData/routing-ui.xcresult"
SHOTS="DerivedData/routing-ui-shots"
: > "$LOG"
rm -rf "$RESULT" "$SHOTS"

# Window geometry only, exactly as smoke.sh does; never the whole defaults domain.
for key in "NSWindow Frame main" "NSWindow Frame com_apple_SwiftUI_Settings_window"; do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done

echo "[routing-ui] building… (full output → $LOG)"
if ! ./scripts/build.sh >>"$LOG" 2>&1; then
  echo "ROUTING UI FAIL: build failed — see $LOG"
  tail -n 30 "$LOG"
  exit 1
fi
xcodegen generate >>"$LOG" 2>&1

osascript -e 'display notification "Routing UI tests take the foreground in 10 seconds" with title "Flight Deck"' || true
echo "[routing-ui] taking the foreground in 10 s…"
sleep 10

set +e
TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1 xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData -resultBundlePath "$RESULT" \
  test -only-testing:FlightDeckUITests/RoutingUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS" >>"$LOG" 2>&1; then
  echo "[routing-ui] screenshots → $SHOTS"
else
  echo "[routing-ui] could not export screenshots — see $LOG"
fi

if [ "$rc" -ne 0 ]; then
  echo "ROUTING UI FAIL (rc=$rc) — full log: $LOG"
  exit "$rc"
fi
echo "ROUTING UI PASS"
