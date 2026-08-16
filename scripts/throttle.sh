#!/usr/bin/env bash
# Run-rate guard, sourced by smoke.sh only.
#
# The UI suite spawns Flight Deck, seizes the foreground, and fires key events
# into whatever holds focus, so a loop of agents each re-running it makes the
# machine unusable. This caps UI runs at one per $FLIGHTDECK_TEST_THROTTLE
# seconds (default 120).
#
# test-unit.sh is deliberately NOT throttled: it runs headless via `xcrun
# xctest` and never takes the foreground, so implementers keep a normal
# red/green TDD cycle.
#
# The stamp is written BEFORE the run, not after, so a long or crashed run
# still counts against the window.
#
# Deliberate one-off override:
#   FLIGHTDECK_TEST_THROTTLE=0 ./scripts/test-unit.sh

THROTTLE=${FLIGHTDECK_TEST_THROTTLE:-120}
STAMP="${TMPDIR:-/tmp}/.flightdeck-test-last-run"

if [ "$THROTTLE" -gt 0 ] && [ -f "$STAMP" ]; then
  now=$(date +%s)
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  elapsed=$(( now - last ))
  remaining=$(( THROTTLE - elapsed ))
  if [ "$remaining" -gt 0 ]; then
    echo "error: a test run started ${elapsed}s ago; these runs take over the machine." >&2
    echo "       Wait ${remaining}s (cap: one run per ${THROTTLE}s)." >&2
    echo "       Deliberate override: FLIGHTDECK_TEST_THROTTLE=0 $0" >&2
    exit 2
  fi
fi

date +%s > "$STAMP"
