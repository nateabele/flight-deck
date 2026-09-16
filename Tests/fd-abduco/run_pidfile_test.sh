#!/usr/bin/env bash
# Tests/fd-abduco/run_pidfile_test.sh — proves the daemon drops a
# "<socket>.pid" sidecar containing its own live pid at session creation,
# and that both the socket and the pidfile disappear once that pid is
# SIGTERM'd (see server_write_pidfile()/server_remove_pidfile() in
# vendor/fd-abduco/server.c).
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdp.XXXXXX).sock
"$BIN" -n "$SOCK" sh -c 'sleep 30'
sleep 0.5
test -f "$SOCK.pid"
PID=$(cat "$SOCK.pid"); kill -0 "$PID"
kill -TERM "$PID"
for i in $(seq 1 20); do test -e "$SOCK.pid" || break; sleep 0.1; done
test ! -e "$SOCK.pid" && test ! -e "$SOCK"
echo "pidfile OK"
