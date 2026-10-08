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

#
# Knobs (all optional):
#   FD_TEST_FILTER=ClassA,ClassB/testX  run only these, in one process (xctest -XCTest syntax).
#                                       Every class name is checked first: xctest itself
#                                       silently runs NOTHING for a misspelled class.
#   FD_TEST_SHARDS=N                    parallel xctest processes for a full run (default 6;
#                                       1 = the old serial run).
#   FD_SKIP_BUILD=1                     reuse the last build-for-testing as is.
#
# scripts/test-serial-classes.txt lists classes that flake under parallel shards (a wall-clock
# deadline, a Task-scheduling interleaving, or the shared mDNSResponder daemon — see its header).
# They are pulled out of every shard and run together in one extra xctest process after the
# parallel shards finish, so shard contention never touches them. FD_TEST_FILTER bypasses this
# list entirely — it always runs in one process regardless of which classes it names.

CONFIG=Debug
PRODUCTS="DerivedData/Build/Products/${CONFIG}"
SHARDS="${FD_TEST_SHARDS:-6}"
TIMINGS_CACHE="DerivedData/fd-test-class-timings.tsv"   # refreshed by every sharded run
TIMINGS_SEED="scripts/test-class-timings.tsv"            # committed fallback for a fresh worktree

if [ -z "${FD_SKIP_BUILD:-}" ]; then
  xcodegen generate
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
    -configuration "$CONFIG" -destination 'platform=macOS' \
    -derivedDataPath DerivedData build-for-testing
fi

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
run_xctest() {  # $1: an -XCTest selector, or empty for the whole bundle
  if [ -n "$1" ]; then set -- -XCTest "$1"; else set --; fi
  DYLD_LIBRARY_PATH="$APPMACOS" DYLD_FRAMEWORK_PATH="$APPMACOS:$APPFRAMEWORKS" \
    "$XCTEST" "$@" "$BUNDLE"
}

# A crashed process aborts mid-test with no "failed (" line for the usual grep to find — the
# log just stops. Falling back to the last "started" line names what it was running when it
# died, instead of a bare "FAILED" with nothing to go on.
report_failure() {  # $1: a shard or serial-lane log
  local log="$1" hits
  hits="$(rg -N 'error:|\) failed \(' "$log" || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
  else
    local started
    started="$(rg -o "Test Case '-\[[^]]+\]' started" "$log" | tail -1)"
    echo "  no error/failed line captured — looks crashed; last test that started: ${started:-(none captured)}"
  fi
}

# The class list comes from source, not the binary. It matched the executed set exactly
# (342/342) when this was written. A class declared some other way (with an attribute on the same line,
# or via a base class other than XCTestCase) would be silently skipped
# by a sharded or filtered run, so keep test classes to the plain form.
ALL_CLASSES="$(rg -o --no-filename '^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase' -r '$1' \
  Tests/FlightDeckTests | sort -u)"

if [ -n "${FD_TEST_FILTER:-}" ]; then
  for sel in ${FD_TEST_FILTER//,/ }; do
    cls="${sel%%/*}"; cls="${cls#FlightDeckTests.}"
    # A here-string, not `printf | rg -q`: rg -q exits at its first match, and under
    # pipefail a printf still writing then takes SIGPIPE and fails the whole pipeline, which
    # reported a real class as unknown (measured: 3 in 2000 under CPU contention, every time
    # once the list outgrows a pipe buffer).
    rg -qx "$cls" <<<"$ALL_CLASSES" \
      || { echo "error: FD_TEST_FILTER names unknown test class '$cls'" >&2; exit 2; }
  done
  run_xctest "$FD_TEST_FILTER"
  exit
fi

SERIAL_FILE="scripts/test-serial-classes.txt"
SERIAL_CLASSES=""
if [ -f "$SERIAL_FILE" ]; then
  SERIAL_CLASSES="$(sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$SERIAL_FILE" \
    | sed '/^$/d' | sort -u)"
fi
if [ -n "$SERIAL_CLASSES" ]; then
  unknown="$(comm -13 <(printf '%s\n' "$ALL_CLASSES") <(printf '%s\n' "$SERIAL_CLASSES"))"
  [ -z "$unknown" ] \
    || { echo "error: $SERIAL_FILE names unknown test class(es): $(printf '%s\n' "$unknown" | tr '\n' ' ')" >&2; exit 2; }
fi
# The parallel shards never see a serial-lane class; it runs once, on its own, below.
CLASSES="$(comm -23 <(printf '%s\n' "$ALL_CLASSES") <(printf '%s\n' "$SERIAL_CLASSES"))"

if [ "$SHARDS" -le 1 ]; then
  run_xctest ""
  exit
fi

# Why shards: the suite's cost is wall-clock WAITING, not CPU. A serial run measured 107s
# wall for ~2s of xctest CPU — the slow tests are negative-assertion polls and socket
# deadlines (PairingWindowTests alone is 21s of sleeping). N processes cut the wall time
# ~N-fold for no extra CPU, which matters on a box already at load 25. Classes are dealt
# longest-first to the least-loaded shard using the last run's per-class times, so the
# floor is the slowest single class (~21s), not the sum.
LOGDIR="DerivedData/fd-test-shards"
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
TIMINGS="$TIMINGS_CACHE"; [ -f "$TIMINGS" ] || TIMINGS="$TIMINGS_SEED"
printf '%s\n' "$CLASSES" | python3 -c '
import sys, os
n, logdir, timings = int(sys.argv[1]), sys.argv[2], sys.argv[3]
known = {}
if os.path.exists(timings):
    for line in open(timings):
        c, t = line.rstrip("\n").split("\t"); known[c] = float(t)
shards = [[0.0, []] for _ in range(n)]
for c in sorted(sys.stdin.read().split(), key=lambda c: -known.get(c, 0.05)):
    s = min(shards, key=lambda s: s[0]); s[0] += known.get(c, 0.05); s[1].append(c)
for i, (_, cs) in enumerate(shards):
    open(f"{logdir}/shard{i}.sel", "w").write(",".join(cs))
' "$SHARDS" "$LOGDIR" "$TIMINGS"

pids=()
for ((i = 0; i < SHARDS; i++)); do
  [ -s "$LOGDIR/shard$i.sel" ] || continue
  run_xctest "$(cat "$LOGDIR/shard$i.sel")" > "$LOGDIR/shard$i.log" 2>&1 &
  pids+=("$i:$!")
done
rc=0
for entry in "${pids[@]}"; do
  i="${entry%%:*}"
  if ! wait "${entry#*:}"; then
    rc=1
    echo "=== shard $i FAILED ($LOGDIR/shard$i.log)" >&2
    report_failure "$LOGDIR/shard$i.log" >&2
  fi
done

# The serial lane: everything scripts/test-serial-classes.txt names, in one xctest process,
# after every parallel shard has finished — so nothing it runs ever shares a CPU-contended
# process, a socket, or the Bonjour daemon with a sibling shard.
SERIAL_LOG="$LOGDIR/serial.log"
: > "$SERIAL_LOG"
if [ -n "$SERIAL_CLASSES" ]; then
  selector="$(printf '%s\n' "$SERIAL_CLASSES" | paste -sd, -)"
  if ! run_xctest "$selector" > "$SERIAL_LOG" 2>&1; then
    rc=1
    echo "=== serial lane FAILED ($SERIAL_LOG)" >&2
    report_failure "$SERIAL_LOG" >&2
  fi
fi

# Refresh the per-class timings the next run balances with, and report one total.
cat "$LOGDIR"/shard*.log "$SERIAL_LOG" | python3 -c '
import re, sys, collections
t = collections.Counter(); n = 0
for l in sys.stdin:
    m = re.search(r"Test Case .-\[\w+\.(\w+) \w+\]. \w+ \(([\d.]+) seconds\)", l)
    if m: t[m[1]] += float(m[2]); n += 1
open(sys.argv[1], "w").write("".join(f"{c}\t{v:.3f}\n" for c, v in sorted(t.items())))
print(f"Executed {n} test cases across all shards")
' "$TIMINGS_CACHE"
serial_note=""
if [ -n "$SERIAL_CLASSES" ]; then serial_note=" + serial lane"; fi
echo "** SHARDED UNIT RUN $([ "$rc" = 0 ] && echo PASSED || echo FAILED) ($SHARDS shards$serial_note; logs in $LOGDIR) **"
