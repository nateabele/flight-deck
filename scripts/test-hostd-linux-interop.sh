#!/usr/bin/env bash
# scripts/test-hostd-linux-interop.sh — §3.2 gate and Linux hostd integration.
# Builds Packages/HostDaemonLinux in swift:6.3-noble, runs it on a published port, then runs
# the Darwin side through test-unit.sh scoped to the interop classes.
#
# Prerequisite for `pair` (and anything later that links SPAKE2): ./scripts/build-boringssl-linux.sh
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=swift:6.3-noble
NAME=fd-hostd-interop-$$
PORT=${FD_INTEROP_PORT:-47411}
MODE=${1:-echo}            # echo (gate 1) | pair (gate 2) | serve (task 6)
# A fixed code, minted once with `PairingCode.mint()` and pasted here: the server is told it on
# its command line and the Darwin test reads it from the environment, so both ends type the
# same code with no channel between them. It protects nothing — the pairing it opens is one
# this script started on loopback and tears down.
CODE=GBH1-XW2F-Y4HW
case "$MODE" in
  # The gate tests each mode exists to run. A run of that mode in which any of them did not
  # pass — skipped included — fails, so a test that quietly XCTSkips (an env variable renamed
  # on one side, a filter that excludes it) cannot report a gate green.
  echo) SUBCOMMAND=echo; EXTRA=(); GATE=(testEchoOverPSKWebSocket testWrongKeyIsRefused) ;;
  pair) SUBCOMMAND=pair-test; EXTRA=(--code "$CODE"); GATE=(testDarwinInitiatorPairsWithLinuxResponder) ;;
  *)    SUBCOMMAND=$MODE; EXTRA=(); GATE=() ;;
esac
# Mounted at its own resolved path as well as through /src: in a worktree
# vendor/boringssl-artifacts is a symlink to the main checkout's (AGENTS.md), which dangles
# inside the container unless its target exists there too, and the linker then reports a
# missing -lcrypto for an archive that is sitting on disk.
ARTIFACTS=$(cd vendor/boringssl-artifacts && pwd -P)
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
  -v "$PWD:/src" -v "$ARTIFACTS:$ARTIFACTS" -w /src/Packages/HostDaemonLinux "$IMAGE" \
  bash -c "swift build -c debug && .build/debug/HostDaemonLinux $SUBCOMMAND --port $PORT \
           --slot 6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00 --secret-hex $(printf '5a%.0s' {1..32}) \
           ${EXTRA[*]:-}" >/dev/null
# A fresh log per run, not a fixed /tmp path: two concurrent runs (another session, another
# mode) would otherwise interleave into one file and each grade the other's results.
LOG=$(mktemp "${TMPDIR:-/tmp}/fd-interop.XXXXXX")
# No `--rm`: a container that dies (a TLS config BoringSSL rejects, a build error) would take
# its log with it, and that log is the only server-side evidence of why. The trap prints it
# on any failure, then removes the container.
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- hostd container log ($NAME) ---"; docker logs "$NAME" 2>&1 | tail -200 || true
    echo "--- Darwin log kept at $LOG ---"
  else
    rm -f "$LOG"
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
until docker logs "$NAME" 2>&1 | rg -q "listening on"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] \
    || { echo "container died"; exit 1; }
  sleep 1
done
FD_LINUX_HOSTD_ENDPOINT="127.0.0.1:$PORT" FD_LINUX_HOSTD_MODE="$MODE" FD_LINUX_HOSTD_CODE="$CODE" \
  FD_TEST_FILTER="${FD_INTEROP_FILTER:-LinuxHostdInteropTests}" \
  ./scripts/test-unit.sh 2>&1 | tee "$LOG"
# `if`, not a bare `! rg`: set -e does not apply to a negated command, so `! rg` stops the
# script only when it is the last line — which it no longer is.
if rg -n "error:|failed \(" "$LOG"; then exit 1; fi
for test in ${GATE[@]+"${GATE[@]}"}; do
  rg -q "LinuxHostdInteropTests $test\]' passed" "$LOG" \
    || { echo "gate test $test did not pass in $MODE mode (skipped or not run):"; \
         rg -n "LinuxHostdInteropTests $test\]'" "$LOG" || true; exit 1; }
done
