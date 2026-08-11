#!/usr/bin/env bash
# Run-rate guard, sourced by test-unit.sh and smoke.sh.
#
# Both scripts build the app and load or launch it. The UI suite in particular
# spawns Flight Deck and takes over the foreground, so a loop of agents each
# re-running the suite makes the machine unusable. This caps ALL test runs —
# unit and UI share one stamp — at one per $FLIGHTDECK_TEST_THROTTLE seconds
# (default 180).
#
# The stamp is written BEFORE the run, not after, so a long or crashed run
# still counts against the window.
#
# Deliberate one-off override:
#   FLIGHTDECK_TEST_THROTTLE=0 ./scripts/test-unit.sh

THROTTLE=${FLIGHTDECK_TEST_THROTTLE:-180}
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
