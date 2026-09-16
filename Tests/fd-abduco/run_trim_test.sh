#!/usr/bin/env bash
# Tests/fd-abduco/run_trim_test.sh — proves the output-log budget trim is
# actually wired through the live daemon: a session that emits far more than
# FD_OUTLOG_BUDGET is attached after the fact, and the replay must contain
# only the trimmed tail (starting at the last screen-clear), not the early
# bulk.
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
SOCK=$(mktemp -u /tmp/fdt.XXXXXX).sock

# 64 KiB of 'x', then a clear, then a unique tail; budget 4 KiB.
FD_OUTLOG_BUDGET=4096 "$BIN" -n "$SOCK" sh -c \
	'head -c 65536 /dev/zero | tr "\0" x; printf "\033[2JTAIL-99\n"; sleep 30'
sleep 0.6
test -S "$SOCK"

cc -Wall -O0 -I vendor/fd-abduco -DWANT_MARKER='"TAIL-99"' -DWANT_ABSENT='"xxxxxxxxxx"' \
   -o /tmp/fd_trim_test Tests/fd-abduco/test_replay.c

set +e
/tmp/fd_trim_test "$SOCK"
rc=$?
set -e

pkill -f "$SOCK" 2>/dev/null || true
exit $rc
