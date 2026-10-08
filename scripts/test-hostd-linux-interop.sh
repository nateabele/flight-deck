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
MODE=${1:-echo}            # echo (gate 1) | pair, pair-wrong (gate 2) | serve (task 6) | run (delegation)
# serve and run take the hostd's own default port, 47410: serve because the pairing window it
# arms binds 47411 inside the same container, run because it is the real `serve` too. The gate
# modes keep 47411, the pairing port they stand in for.
case "$MODE" in serve|run) PORT=${FD_INTEROP_PORT:-47410} ;; *) PORT=${FD_INTEROP_PORT:-47411} ;; esac
# A fixed code, minted once with `PairingCode.mint()` and pasted here: the server is told it on
# its command line and the Darwin test reads it from the environment, so both ends type the
# same code with no channel between them. It protects nothing — the pairing it opens is one
# this script started on loopback and tears down.
CODE=GBH1-XW2F-Y4HW
# pair-wrong arms the server with this one instead, so every Darwin attempt is a wrong guess.
WRONG_CODE=F0D3-AKHV-BX61
SLOT=6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00
SECRET_HEX=$(printf '5a%.0s' {1..32})
# EXPECT_EXIT: the server's exit status the mode requires once the tests are done, or empty
# for a server that is meant to still be running.
EXPECT_EXIT=
PUBLISH=()
# The XCTest class holding the mode's gate tests.
CLASS=LinuxHostdInteropTests
case "$MODE" in
  # The gate tests each mode exists to run. A run of that mode in which any of them did not
  # pass — skipped included — fails, so a test that quietly XCTSkips (an env variable renamed
  # on one side, a filter that excludes it) cannot report a gate green.
  echo) ARGS=(echo --port "$PORT" --slot "$SLOT" --secret-hex "$SECRET_HEX")
        GATE=(testEchoOverPSKWebSocket testWrongKeyIsRefused) ;;
  pair) ARGS=(pair-test --port "$PORT" --slot "$SLOT" --secret-hex "$SECRET_HEX" --code "$CODE")
        GATE=(testDarwinInitiatorPairsWithLinuxResponder) ;;
  # The burned window must also end the responder with exit 1: that exit is what `pair`
  # reports to the user, and a verdict lost to a peer hanging up first would leave it running.
  pair-wrong)
        ARGS=(pair-test --port "$PORT" --slot "$SLOT" --secret-hex "$SECRET_HEX" --code "$WRONG_CODE")
        GATE=(testWrongCodeExhaustsTheLinuxWindow); EXPECT_EXIT=1 ;;
  # FD_HOSTD_TEST=1 is what lets --test-controller seed the store; the real hostd refuses it.
  serve) ARGS=(serve --port "$PORT" --root /tmp/fdroot --test-controller "$SLOT:$SECRET_HEX")
        GATE=(testHelloAndHostInfoAgainstLinuxHostd testRevokedControllerIsDisconnected
              testPairThroughServeThenHelloRenamesTheController)
        # The pairing window `pair` arms inside the container listens on 47411.
        PUBLISH=(-p "127.0.0.1:47411:47411") ;;
  # Delegated execution on the real serve: the app's DelegationService syncs a temp repo, runs
  # `echo`, then `git status` in the synced checkout, over the NIO transport and Linux router.
  run)  ARGS=(serve --port "$PORT" --root /tmp/fdroot --test-controller "$SLOT:$SECRET_HEX")
        CLASS=LinuxHostdRunInteropTests
        GATE=(testDelegatedRunAgainstLinuxHostd) ;;
  *)    echo "unknown mode $MODE" >&2; exit 64 ;;
esac
# Refuse up front when a port this mode publishes is already taken. serve and run publish
# 47410, which this Mac's own hostd holds while Settings → Hosting is on; without this check
# `docker run` failed with "failed to bind host port … address already in use", exit 125, and
# left a Created container behind (the cleanup trap is armed only after it). A connect, not
# lsof: bash's /dev/tcp is on every Mac and Linux box, lsof is not on every Linux image.
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "$PORT" ${PUBLISH[@]+"${PUBLISH[@]}"}; do
  case "$p" in -p) continue ;; *:*:*) p=${p#*:}; p=${p%%:*} ;; esac
  if port_in_use "$p"; then
    echo "127.0.0.1:$p is already in use, and $MODE mode publishes it." >&2
    [ "$p" = 47410 ] && echo "This Mac's own hostd listens there: turn Settings → Hosting off first." >&2
    exit 2
  fi
done
# Mounted at its own resolved path as well as through /src: in a worktree
# vendor/boringssl-artifacts is a symlink to the main checkout's (AGENTS.md), which dangles
# inside the container unless its target exists there too, and the linker then reports a
# missing -lcrypto for an archive that is sitting on disk.
ARTIFACTS=$(cd vendor/boringssl-artifacts && pwd -P)
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" ${PUBLISH[@]+"${PUBLISH[@]}"} -e FD_HOSTD_TEST=1 \
  -v "$PWD:/src" -v "$ARTIFACTS:$ARTIFACTS" -w /src/Packages/HostDaemonLinux "$IMAGE" \
  bash -c "swift build -c debug && exec .build/debug/HostDaemonLinux ${ARGS[*]}" >/dev/null
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
  FD_LINUX_HOSTD_CONTAINER="$NAME" FD_LINUX_HOSTD_PAIRING_ENDPOINT="127.0.0.1:47411" \
  FD_TEST_FILTER="${FD_INTEROP_FILTER:-$CLASS}" \
  ./scripts/test-unit.sh 2>&1 | tee "$LOG"
# `if`, not a bare `! rg`: set -e does not apply to a negated command, so `! rg` stops the
# script only when it is the last line — which it no longer is.
if rg -n "error:|failed \(" "$LOG"; then exit 1; fi
for test in ${GATE[@]+"${GATE[@]}"}; do
  rg -q "$CLASS $test\]' passed" "$LOG" \
    || { echo "gate test $test did not pass in $MODE mode (skipped or not run):"; \
         rg -n "$CLASS $test\]'" "$LOG" || true; exit 1; }
done
if [ -n "$EXPECT_EXIT" ]; then
  for _ in $(seq 1 15); do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] && break
    sleep 1
  done
  got=$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "$NAME")
  [ "$got" = "false $EXPECT_EXIT" ] \
    || { echo "server should have exited $EXPECT_EXIT in $MODE mode; running/exit: $got"; exit 1; }
fi
