#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# macOS window-restoration guard: if Flight Deck has stale saved window state,
# the OS may restore its window off-screen (or leave it suppressed) the next
# time it launches. That makes the UI test flaky - the window "exists" per
# Accessibility but isn't where a fresh launch would place it, so a size/
# existence assertion can pass or fail nondeterministically. Clear any saved
# state before each smoke run so the app always launches fresh and on-screen.
defaults delete dev.flightdeck.FlightDeck 2>/dev/null || true
rm -f ~/Library/Preferences/dev.flightdeck.FlightDeck.plist 2>/dev/null || true

./scripts/build.sh
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
  test -only-testing:FlightDeckUITests
echo "SMOKE PASS"
