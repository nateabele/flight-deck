#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# The window-free logic lane: Tests/IntakeKitTests and Tests/FleetKitTests, on THIS Mac.
#
# Why it exists: every FlightDeckTests run is app-hosted and goes to the one UI-test Mac under
# a single global lock (scripts/test-unit-remote.sh). Pure IntakeKit/FleetKit tests need no app and no
# window, so they live in two plain xctest bundles (no TEST_HOST, no BUNDLE_LOADER: see
# project.yml) that `xcodebuild test` runs in the xctest process. Nothing here opens a window,
# takes focus, or touches the remote host or its lock, so worktrees can run it in parallel;
# each one has its own DerivedData.
#
# Knobs (all optional):
#   FD_TEST_FILTER=ClassA,ClassB/testX   run only these. Comma-separated, like test-unit.sh. A
#                                        class that is in neither bundle is an error (exit 2):
#                                        xcodebuild would otherwise run nothing and say PASSED.
#   FD_SKIP_BUILD=1                      skip `xcodegen generate` (xcodebuild still builds
#                                        incrementally, which is cheap).
#
# Exits non-zero on any failure, a build error, or zero tests executed. (test-unit.sh exits 0
# on failures; callers of this script can trust the status.)

INTAKE_DIR=Tests/IntakeKitTests
FLEET_DIR=Tests/FleetKitTests
LOG="DerivedData/fd-logic-test.log"
mkdir -p DerivedData

# Which bundle a class lives in comes from source, the same way test-unit.sh finds its classes.
bundle_of() {  # $1: class name
  local pat="^\s*(final\s+)?class\s+$1\s*:\s*XCTestCase"
  if rg -q "$pat" "$INTAKE_DIR" 2>/dev/null; then echo IntakeKitTests
  elif rg -q "$pat" "$FLEET_DIR" 2>/dev/null; then echo FleetKitTests
  fi
}

ONLY=()
if [ -n "${FD_TEST_FILTER:-}" ]; then
  for sel in ${FD_TEST_FILTER//,/ }; do
    cls="${sel%%/*}"
    cls="${cls#IntakeKitTests.}"; cls="${cls#FleetKitTests.}"
    b="$(bundle_of "$cls")"
    [ -n "$b" ] || { echo "error: FD_TEST_FILTER names '$cls', which is not a test class in $INTAKE_DIR or $FLEET_DIR" >&2; exit 2; }
    rest=""; [ "$sel" != "$cls" ] && rest="/${sel#*/}"
    ONLY+=(-only-testing:"$b/$cls$rest")
  done
fi

if [ -z "${FD_SKIP_BUILD:-}" ]; then
  xcodegen generate >/dev/null
fi

rc=0
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckLogic \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  ${ONLY[@]+"${ONLY[@]}"} test > "$LOG" 2>&1 || rc=$?

# `Test Case '-[Bundle.Class testX]' passed (0.001 seconds).` is one line per test.
passed="$(rg -c "^Test Case '.*' passed" "$LOG" || true)"; passed="${passed:-0}"
failed="$(rg -c "^Test Case '.*' failed" "$LOG" || true)"; failed="${failed:-0}"

# Build errors, assertion failures and crashes, all of which xcodebuild buries in the log.
if [ "$rc" != 0 ] || [ "$failed" != 0 ]; then
  rg -N 'error:|\) failed \(|Test Suite .* failed|\*\* TEST FAILED|\*\* BUILD FAILED' "$LOG" | sort -u | head -60 >&2 || true
fi

if [ "$rc" = 0 ] && [ "$failed" = 0 ] && [ "$passed" = 0 ]; then
  echo "error: no tests executed (see $LOG)" >&2
  rc=1
fi
[ "$failed" != 0 ] && rc=1

echo "** LOGIC TESTS $([ "$rc" = 0 ] && echo PASSED || echo FAILED): $passed passed, $failed failed (log: $LOG) **"
exit "$rc"
