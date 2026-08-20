#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Headless unit-test runner for FlightDeckTests.
#
# Why this exists: FlightDeckTests is an app-hosted unit-test bundle (it depends
# on the FlightDeck application target so it can `@testable import FlightDeck`).
# `xcodebuild ... test` therefore tries to LAUNCH "Flight Deck.app" as the test
# host, which fails in any non-interactive / automated context with
# `DVTAssertions: Assertion failed: childPID > 0` — the launch-services spawn
# needs a full GUI login session. Those are pure-logic tests (models, store,
# resolvers) that never need a window, so we run them in-process instead:
#
#   1. build-for-testing  → compiles the app dylib + the .xctest bundle
#   2. symlink the app's testable dylib into the bundle's Frameworks dir so the
#      bundle's `@rpath/Flight Deck.debug.dylib` resolves without a host launch
#   3. `xcrun xctest` loads and runs the bundle directly (no GUI app spawned)
#
# UI tests (FlightDeckUITests) genuinely drive the app and still require
# scripts/smoke.sh + a one-time UI-automation TCC grant; this script is only for
# the headless unit suite.

CONFIG=Debug
PRODUCTS="DerivedData/Build/Products/${CONFIG}"

xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath DerivedData build-for-testing

BUNDLE="${PRODUCTS}/Flight Deck.app/Contents/PlugIns/FlightDeckTests.xctest"
APPMACOS="$PWD/${PRODUCTS}/Flight Deck.app/Contents/MacOS"
DYLIB="$APPMACOS/Flight Deck.debug.dylib"  # absolute: ln -s resolves relative to the link dir

[ -d "$BUNDLE" ] || { echo "error: test bundle not found at $BUNDLE" >&2; exit 1; }
[ -f "$DYLIB" ]  || { echo "error: host dylib not found at $DYLIB" >&2; exit 1; }

# Satisfy the bundle's @rpath lookup for the host's testable dylib. The symlink
# lives inside DerivedData (git-ignored, wiped on clean) so we recreate it every
# run; -f makes that idempotent.
mkdir -p "$BUNDLE/Contents/Frameworks"
ln -sf "$DYLIB" "$BUNDLE/Contents/Frameworks/Flight Deck.debug.dylib"

APPFRAMEWORKS="$PWD/${PRODUCTS}/Flight Deck.app/Contents/Frameworks"

# Resolve the real xctest binary instead of going through `xcrun xctest`. /usr/bin/xcrun
# lives under a SIP-protected path, and dyld strips every DYLD_* variable before exec'ing
# any binary there — so DYLD_FRAMEWORK_PATH below would be silently dropped before xctest
# ever started, and FleetKit.framework would fail to resolve with no explanation. The
# resolved path is under /Applications/Xcode.app, which isn't SIP-restricted, so invoking
# it directly lets the variable survive.
XCTEST="$(xcrun --find xctest)"

# Contents/Frameworks joins the search path for FleetKit.framework, which the test bundle
# links but does not embed. Without it `xctest` aborts at load with an @rpath failure that
# reads like a missing symbol rather than a missing directory.
DYLD_LIBRARY_PATH="$APPMACOS" DYLD_FRAMEWORK_PATH="$APPMACOS:$APPFRAMEWORKS" \
  "$XCTEST" "$BUNDLE"
