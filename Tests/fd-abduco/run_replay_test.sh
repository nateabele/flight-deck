#!/usr/bin/env bash
# Tests/fd-abduco/run_replay_test.sh — protocol-level replay test: a session
# prints a marker then idles; a raw socket client attaches after the fact and
# must see the marker via history replay.
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
SOCK=$(mktemp -u /tmp/fdr.XXXXXX).sock

FD_OUTLOG_BUDGET=1048576 "$BIN" -n "$SOCK" sh -c 'printf "MARKER-12345\n"; sleep 30'
sleep 0.6
test -S "$SOCK"

cc -Wall -O0 -I vendor/fd-abduco -o /tmp/fd_replay_test Tests/fd-abduco/test_replay.c

set +e
/tmp/fd_replay_test "$SOCK"
rc=$?
set -e

pkill -f "$SOCK" 2>/dev/null || true
exit $rc
