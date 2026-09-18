#!/usr/bin/env bash
# Tests/fd-abduco/run_mode_preamble_test.sh — end-to-end proof that the
# server.c wiring actually sends the synthesized mode preamble over the
# wire: a session sets DEC private mode 1000 (mouse tracking) right at
# startup, then emits far more than FD_OUTLOG_BUDGET's worth of filler so
# the original set sequence (and the marker right after it) are trimmed out
# of history entirely; a client attaching afterward must still see the mode
# re-asserted via the preamble even though it's no longer anywhere in the
# replayed history.
#
# Notes vs. a naive invocation (see vendor/fd-abduco/PROVENANCE.md):
#   - abduco's argv grammar has no `--` end-of-options marker.
#   - `-n` creates a session WITHOUT attaching (true detached/daemon
#     behavior) and returns almost immediately once the session is created;
#     the actual daemon keeps running detached, so there is nothing useful to
#     background here.
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdm.XXXXXX).sock

# Enable mouse tracking (mode 1000) and print a marker right next to it,
# then 64 KiB of filler; budget 4 KiB so both are long gone from history.
FD_OUTLOG_BUDGET=4096 "$BIN" -n "$SOCK" sh -c \
	'printf "\033[?1000hSTART-99"; head -c 65536 /dev/zero | tr "\0" x; sleep 30'
sleep 0.6
test -S "$SOCK"

cc -Wall -O0 -I vendor/fd-abduco \
   -DWANT_MARKER='"\x1b[?1000h"' -DWANT_ABSENT='"START-99"' \
   -o /tmp/fd_mode_preamble_test Tests/fd-abduco/test_replay.c

set +e
/tmp/fd_mode_preamble_test "$SOCK"
rc=$?
set -e

pkill -f "$SOCK" 2>/dev/null || true
exit $rc
