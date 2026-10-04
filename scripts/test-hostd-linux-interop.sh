#!/usr/bin/env bash
# scripts/test-hostd-linux-interop.sh — §3.2 gate and Linux hostd integration.
# Builds Packages/HostDaemonLinux in swift:6.3-noble, runs it on a published port, then runs
# the Darwin side through test-unit.sh scoped to the interop classes.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=swift:6.3-noble
NAME=fd-hostd-interop-$$
PORT=${FD_INTEROP_PORT:-47411}
MODE=${1:-echo}            # echo (gate 1) | pair (gate 2) | serve (task 6)
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
  -v "$PWD:/src" -w /src/Packages/HostDaemonLinux "$IMAGE" \
  bash -c "swift build -c debug && .build/debug/HostDaemonLinux $MODE --port $PORT \
           --slot 6F0B2C1E-8E37-4D7A-9D0A-3C5E2B1A9F00 --secret-hex $(printf '5a%.0s' {1..32})" >/dev/null
# No `--rm`: a container that dies (a TLS config BoringSSL rejects, a build error) would take
# its log with it, and that log is the only server-side evidence of why. The trap prints it
# on any failure, then removes the container.
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- hostd container log ($NAME) ---"; docker logs "$NAME" 2>&1 | tail -200 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
until docker logs "$NAME" 2>&1 | rg -q "listening on"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] \
    || { echo "container died"; exit 1; }
  sleep 1
done
FD_LINUX_HOSTD_ENDPOINT="127.0.0.1:$PORT" FD_TEST_FILTER="${FD_INTEROP_FILTER:-LinuxHostdInteropTests}" \
  ./scripts/test-unit.sh 2>&1 | tee /tmp/fd-interop.log
! rg -n "error:|failed \(" /tmp/fd-interop.log
