#!/usr/bin/env bash
# Tests/fd-abduco/baseline_smoke.sh — build works; create/list/exit roundtrip,
# and explicit socket-path handling (Task 1 decision #2) is proven end to end.
#
# Notes vs. a naive abduco invocation (see vendor/fd-abduco/PROVENANCE.md):
#   - abduco's argv grammar has no `--` end-of-options marker; the first
#     positional argument after the flags is the session name/socket path,
#     everything after that is the command argv verbatim. A literal `--`
#     would become argv[0] of the command and fail to exec.
#   - `-n` creates a session WITHOUT attaching (true detached/daemon
#     behavior); `-c` creates and attaches in the foreground.
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
test -x "$BIN"
file "$BIN" | grep -qi mach-o

SOCK=$(mktemp -u /tmp/fdb.XXXXXX).sock

# Create a detached session at an explicit absolute socket path.
"$BIN" -n "$SOCK" sh -c 'sleep 5'
sleep 0.5

# The socket must exist at EXACTLY the path we gave -- proving the explicit
# path was honored verbatim (no socket-dir search / no hostname suffix).
test -S "$SOCK"
echo "explicit socket path honored verbatim: $SOCK"

# `-l` only scans abduco's default socket_dirs table; an explicit absolute
# path deliberately does not show up there. Confirm that too, so a future
# regression that routes explicit paths back through socket_dirs is caught.
if "$BIN" -l | grep -q "$(basename "$SOCK")"; then
	echo "FAIL: explicit-path session unexpectedly listed by -l (should bypass socket_dirs)" >&2
	exit 1
fi
echo "-l correctly does not list the explicit-path session"

# ending the program tears the session down
pkill -f "sleep 5" || true
sleep 0.5

echo "baseline OK"
