#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Live-codex runner for CodexIntegrationTests only.
#
# How this differs from scripts/test-unit.sh (read that file first — the build/host/
# xctest-resolution steps below are copied from it verbatim, and every comment there
# explaining *why* still applies here unchanged):
#
#   - This spawns REAL `codex app-server`/`codex exec` processes and creates and deletes
#     real threads in the user's CODEX_HOME (~/.codex by default). It is NOT hermetic:
#     it touches live state and, for one test, runs a real model turn that costs tokens.
#   - It is therefore not safe to loop or run repeatedly without reason.
#   - `FLIGHT_DECK_CODEX_INTEGRATION=1` is exported so CodexIntegrationTests.setUpWithError
#     stops skipping itself.
#   - `-XCTest CodexIntegrationTests` on the xctest invocation filters the run to that one
#     class, so the rest of the (already-hermetic) suite doesn't run twice.
#
# A small amount of duplication with test-unit.sh is deliberate: that script is the
# hermetic runner every other task depends on, and is not worth restructuring just to
# share this preamble.

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
FLIGHT_DECK_CODEX_INTEGRATION=1 \
  DYLD_LIBRARY_PATH="$APPMACOS" DYLD_FRAMEWORK_PATH="$APPMACOS:$APPFRAMEWORKS" \
  "$XCTEST" -XCTest CodexIntegrationTests "$BUNDLE"
