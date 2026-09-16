#!/usr/bin/env bash
# Tests/fd-abduco/run_replay_busy_test.sh — covers the ATTACH/RESIZE ordering
# race (see test_replay_busy.c): a session whose child keeps emitting
# numbered lines while the test client deliberately delays MSG_RESIZE after
# MSG_ATTACH, exercising the STATE_CONNECTED-but-not-yet-STATE_ATTACHED gap
# where live output must NOT be forwarded (it would be duplicated by the
# MSG_RESIZE replay that follows).
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdrb.XXXXXX).sock

FD_OUTLOG_BUDGET=1048576 "$BIN" -n "$SOCK" sh -c '
	i=0
	while [ "$i" -lt 30 ]; do
		printf "LINE-%03d\n" "$i"
		i=$((i + 1))
		sleep 0.05
	done
	sleep 30
'
sleep 0.3
test -S "$SOCK"

cc -Wall -O0 -I vendor/fd-abduco -o /tmp/fd_replay_busy_test Tests/fd-abduco/test_replay_busy.c

set +e
/tmp/fd_replay_busy_test "$SOCK"
rc=$?
set -e

pkill -f "$SOCK" 2>/dev/null || true
exit $rc
