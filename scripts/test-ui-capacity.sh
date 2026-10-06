#!/usr/bin/env bash
# Runs CapacityUITests (Flight Control L3-U) and exports its screenshots.
#
# Runs on the UI-test Mac through scripts/smoke-remote.sh, never on this Mac's screen. That
# script builds here, syncs the products, takes the remote lock and its 120 s run-rate cap
# (FLIGHTDECK_TEST_THROTTLE), and writes the result bundle and log to DerivedData/smoke-remote/.
# This wrapper only supplies the selection and the gate: the test skips without it, and ssh
# carries no environment, so smoke-remote.sh bakes every TEST_RUNNER_* into the xctestrun it
# ships. The suite is not part of the smoke gate; run once, never in a loop.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib-local-env.sh
fd_load_local_env
# No default host: the UI-test Mac is machine-specific and must never be written into a committed
# file. Without this check an empty host fails later as an opaque ssh usage error.
if [ -z "${FD_UITEST_HOST:-}" ]; then
  echo "CAPACITY UI FAIL: no UI-test host configured."
  echo "            cp scripts/local.env.example scripts/local.env and set FD_UITEST_HOST"
  echo "            (and FD_UITEST_SSH_KEY if ssh needs an explicit identity file)."
  exit 2
fi

OUT="DerivedData/smoke-remote"
SHOTS="DerivedData/capacity-ui-shots"
rm -rf "$SHOTS"

set +e
FD_UITEST_ONLY="FlightDeckUITests/CapacityUITests" TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1 ./scripts/smoke-remote.sh
rc=$?
set -e

# smoke-remote.sh copies the result bundle back; the screenshots are its attachments.
if [ -d "$OUT/run.xcresult" ] && xcrun xcresulttool export attachments --path "$OUT/run.xcresult" --output-path "$SHOTS" >/dev/null 2>&1; then
  echo "[capacity-ui] screenshots -> $SHOTS"
else
  echo "[capacity-ui] no screenshots exported; result bundle: $OUT/run.xcresult"
fi

if [ "$rc" -ne 0 ]; then echo "CAPACITY UI FAIL (rc=$rc) — see scripts/.smoke.log"; exit "$rc"; fi
echo "CAPACITY UI PASS"
