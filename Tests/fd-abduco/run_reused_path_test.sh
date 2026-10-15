#!/usr/bin/env bash
# Tests/fd-abduco/run_reused_path_test.sh — a daemon that exits after ANOTHER daemon has taken
# its socket path must leave that daemon's socket and pidfile alone.
#
# 2026-10-15: an orphaned daemon whose path had been reused (its socket file gone, a new daemon
# bound in its place) was reaped with SIGTERM. Its atexit handler unlinked the path by name,
# deleting the live daemon's socket and pidfile; the next Flight Deck launch read the tab as
# dead and resumed it a second time, leaving two claudes on one conversation.
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdr.XXXXXX).sock
"$BIN" -n "$SOCK" sh -c 'sleep 30'
sleep 0.5
OLD=$(cat "$SOCK.pid")
rm -f "$SOCK" "$SOCK.pid"            # the path is lost, as when a stray unlink took it
"$BIN" -n "$SOCK" sh -c 'sleep 30'   # a new daemon binds the same path
sleep 0.5
NEW=$(cat "$SOCK.pid")
test "$OLD" != "$NEW"
kill -TERM "$OLD"
for i in $(seq 1 20); do kill -0 "$OLD" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$OLD" 2>/dev/null
test -S "$SOCK" || { echo "FAIL: the exiting daemon deleted the new daemon's socket"; kill -TERM "$NEW"; exit 1; }
test "$(cat "$SOCK.pid")" = "$NEW" || { echo "FAIL: the exiting daemon deleted the new daemon's pidfile"; kill -TERM "$NEW"; exit 1; }
kill -TERM "$NEW"
for i in $(seq 1 20); do test -e "$SOCK" || break; sleep 0.1; done
test ! -e "$SOCK" && test ! -e "$SOCK.pid"
echo "reused path OK"
