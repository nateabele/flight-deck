#!/usr/bin/env bash
# Runs CapacityUITests (Flight Control L3-U) and exports its screenshots.
#
# A UI test takes the foreground and types into whatever holds focus, so this warns first,
# shares smoke.sh's throttle, and is never part of the smoke gate. Run it once; never loop it.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

# Same window-geometry reset as smoke.sh, for the same reason: a restored frame from an earlier
# run wins over SwiftUI's default placement and can put the window off the primary display,
# failing every assertion. ONLY the named geometry keys are deleted — never the whole defaults
# domain, which holds the user's preferences.
for key in \
  "NSWindow Frame main" \
  "NSWindow Frame com_apple_SwiftUI_Settings_window" \
  "NSSplitView Subview Frames main, SidebarNavigationSplitView"
do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done
rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState 2>/dev/null || true

LOG="scripts/.capacity-ui.log"
RESULT="scripts/.capacity-ui.xcresult"
SHOTS="scripts/.capacity-ui-shots"
: > "$LOG"
rm -rf "$RESULT" "$SHOTS"

echo "[capacity-ui] building… (full output → $LOG)"
if ! ./scripts/build.sh >>"$LOG" 2>&1; then
  echo "CAPACITY UI FAIL: build failed — see $LOG"; tail -n 30 "$LOG"; exit 1
fi
xcodegen generate >>"$LOG" 2>&1

osascript -e 'display notification "The capacity UI test takes the foreground in 10 seconds." with title "Flight Deck tests"' >/dev/null 2>&1 || true
echo "[capacity-ui] taking the foreground in 10 s for about a minute (Ctrl-C to cancel)"
sleep 10

set +e
TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1 xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData -resultBundlePath "$RESULT" \
  test -only-testing:FlightDeckUITests/CapacityUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true

mkdir -p "$SHOTS"
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS" >>"$LOG" 2>&1; then
  echo "[capacity-ui] screenshots: $SHOTS"
else
  echo "[capacity-ui] could not export screenshots with this Xcode; open $RESULT in Xcode"
fi

if [ "$rc" -ne 0 ]; then echo "CAPACITY UI FAIL (rc=$rc) — full log: $LOG"; exit "$rc"; fi
echo "CAPACITY UI PASS"
