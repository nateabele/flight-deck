#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../.."

CONFIG=Debug
PRODUCTS="DerivedData/Build/Products/${CONFIG}"
APPMACOS="$PWD/${PRODUCTS}/Flight Deck.app/Contents/MacOS"
DYLIB="$APPMACOS/Flight Deck.debug.dylib"
OUT="DerivedData/adapterprobe"

# Build the app first, exactly as test-unit.sh does: the probe imports the app's own
# swiftmodule, so there is no separate build description to keep in step.
xcodegen generate >/dev/null
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath DerivedData build >/dev/null

[ -f "$DYLIB" ] || { echo "error: host dylib not found at $DYLIB" >&2; exit 1; }
mkdir -p "$OUT"

# -enable-testing on the app target is what makes `@testable import FlightDeck` legal here;
# Debug already sets it, which is how FlightDeckTests imports the same module.
#
# The four non-obvious flags below were each established by compiling a throwaway probe against
# this exact tree; without any one of them the build fails, so do not "simplify" them away:
#
#   -parse-as-library          A ONE-file swiftc invocation is script mode, and `@main` is
#                              illegal in a module with top-level code. (scripts/livefuzz's
#                              probe escapes this only by compiling two files.)
#   -Xcc -I<GhosttyEmbed>      `@testable import` pulls in the module's bridging header, which
#                              #imports ObjCExceptionCatcher.h / VibrantLayer.h.
#   -Xcc -I<boringssl include> FleetKit's BoringSSLShim module map needs openssl/curve25519.h.
#   -Xcc -I<products>/include  The GhosttyKit module map (umbrella header ghostty.h).
#
# The two -Xcc header paths are exactly FlightDeck's own HEADER_SEARCH_PATHS from
# project.yml:101; if that line ever changes, change these with it.
swiftc -O -parse-as-library \
  scripts/adapterprobe/probe.swift \
  -I "$PRODUCTS" \
  -F "$PRODUCTS" \
  -Xcc -I"$PWD/Sources/FlightDeck/GhosttyEmbed" \
  -Xcc -I"$PWD/vendor/boringssl-artifacts/include" \
  -Xcc -I"$PWD/$PRODUCTS/include" \
  -framework FleetKit \
  "$DYLIB" \
  -Xlinker -rpath -Xlinker "$APPMACOS" \
  -Xlinker -rpath -Xlinker "$PWD/$PRODUCTS" \
  -o "$OUT/probe"

echo "built $OUT/probe"
