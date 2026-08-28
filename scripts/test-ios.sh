#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# The phone app's unit suite: FlightDeckMobileTests, on a simulator.
#
# Why this is `xcodebuild test` where scripts/test-unit.sh goes to the trouble of loading the
# bundle by hand: the thing test-unit.sh works around is macOS-specific. There, the test host
# is a real AppKit app and launching it needs a GUI login session, so `xcodebuild test` dies
# with `DVTAssertions: Assertion failed: childPID > 0` in any automated context. A simulator
# host is launched by simctl, not by LaunchServices, and needs no window server of ours — so
# the ordinary path works headless here and there is nothing to route around. Do not port
# test-unit.sh's dylib-symlink dance over; it would be solving a problem this side does not
# have.
#
# These are unit tests, not UI tests: they exercise `TypedCodeField`, `FleetModel` and
# `SessionStatusGlyph.label` inside the app process. What they cannot reach is anything
# SwiftUI renders — layout, caret behaviour, whether `.textInputAutocapitalization` does
# anything — and the camera, which a simulator does not have. Those stay in docs/MOBILE.md's
# checklists; nothing here should grow an assertion that only re-reads the source.

# A device this script creates and destroys, rather than whichever simulator happens to be
# booted. Running the suite INSTALLS the app onto its destination, so pointing this at a
# device someone is using would overwrite the build they are testing — that has happened, and
# it is the entire reason this is not just `-destination 'name=iPhone 17 Pro'`. The cost is a
# cold boot per run (~30s); the benefit is that a run can never disturb anything.
#
# Newest iPhone type available, with no runtime pinned so simctl picks the newest one that
# supports it. The tests are model- and OS-independent — nothing here reads a screen size.
DEVICE_TYPE=$(xcrun simctl list devicetypes \
  | sed -n 's/^iPhone .*(\(com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*\))$/\1/p' \
  | head -1)
[ -n "$DEVICE_TYPE" ] || {
  echo "error: no iPhone simulator device type found. Install an iOS platform:" >&2
  echo "       xcodebuild -downloadPlatform iOS" >&2
  exit 1
}

xcodegen generate

UDID=$(xcrun simctl create "FlightDeckMobileTests-$$" "$DEVICE_TYPE")
echo "== simulator $UDID ($DEVICE_TYPE), created for this run =="
# Deleted however this exits, including on a failing test — a shut-down simulator left behind
# by every red run is how a machine ends up with forty of them.
trap 'xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT

xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath DerivedData test
