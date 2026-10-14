#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# The menu-bar gate: "no menu should blink ever" (2026-10-09). Builds
# scripts/menubar-harness/MenuBarHarness.swift — a bare SwiftUI app linked against this
# checkout's Debug dylib that installs the app's real Commands and AppKit menu controllers over
# the real RootView — runs it, and fails if SwiftUI removed anything from the main menu, or our
# AppKit items went missing, across tab switches, plan/terminal switches, inspector mode
# switches, intake state changes, preference edits, Settings and a second window.
#
# Why not a unit test: only a SwiftUI `App` scene turns `Commands` into a menu bar.
# Why it is safe to run here: the harness never activates (no focus is taken, no key is read),
# its window sits off screen, and it is NOT Flight Deck's app — it has its own `@main`, so none
# of FlightDeckApp's launch work (sessions.json, daemons, `claude --resume`) runs. Its store
# uses a null persistence and a scratch intakes root, like the unit tests'.
#
# Knobs: FD_SKIP_BUILD=1 reuses the last Debug build (run after test-unit.sh / build.sh).
#        FD_MENUBAR_BEFORE=1 compiles the pre-fix command set (only builds against 956ee992).
#        FD_MENUBAR_BUILD_ONLY=1 compiles the harness and stops. Opens nothing.
#        FD_MENUBAR_PREBUILT=1 runs the harness as already compiled, never touching swiftc.
#        test-unit-remote.sh uses the pair: the harness is compiled on THIS Mac with this Xcode,
#        and run on the UI-test Mac, whose older Xcode could not compile it.

P="DerivedData/Build/Products/Debug"
APP="$P/Flight Deck.app/Contents"
if [ -z "${FD_SKIP_BUILD:-}" ]; then
  xcodegen generate >/dev/null
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath DerivedData build-for-testing >/dev/null
fi
[ -f "$APP/MacOS/Flight Deck.debug.dylib" ] || { echo "error: no Debug dylib at $APP/MacOS" >&2; exit 1; }

OUT="DerivedData/menubar-harness"
mkdir -p "$OUT"
FLAGS=(-Onone)
[ -n "${FD_MENUBAR_BEFORE:-}" ] && FLAGS+=(-D BEFORE)
if [ -n "${FD_MENUBAR_PREBUILT:-}" ]; then
  [ -x "$OUT/MenuBarHarness" ] || { echo "error: FD_MENUBAR_PREBUILT=1 but no $OUT/MenuBarHarness" >&2; exit 1; }
else
xcrun swiftc -parse-as-library -target arm64-apple-macos14 "${FLAGS[@]}" \
  -I "$P" -F "$P" -F "$APP/Frameworks" \
  -Xcc -fmodule-map-file="$P/include/module.modulemap" -Xcc -I"Sources/FlightDeck/GhosttyEmbed" \
  -Xcc -I"vendor/boringssl-artifacts/include" -Xcc -I"$P/include" \
  scripts/menubar-harness/MenuBarHarness.swift "$APP/MacOS/Flight Deck.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PWD/$APP/MacOS" -Xlinker -rpath -Xlinker "$PWD/$APP/Frameworks" \
  -Xlinker -rpath -Xlinker "$PWD/$P" \
  -o "$OUT/MenuBarHarness" 2>"$OUT/build.log" || { grep -E "error:" "$OUT/build.log" >&2; exit 1; }
fi
[ -n "${FD_MENUBAR_BUILD_ONLY:-}" ] && exit 0

# 120 s is generous: the run itself is ~30 s.
status=0
"$OUT/MenuBarHarness" >"$OUT/run.log" 2>&1 &
pid=$!
( sleep 120; kill "$pid" 2>/dev/null ) 2>/dev/null &
watchdog=$!
wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
grep -E "^MENUBAR|: removals=" "$OUT/run.log" || { echo "MENUBAR FAIL: no result (see $OUT/run.log)"; exit 1; }
exit "$status"
