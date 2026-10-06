#!/usr/bin/env bash
# Runs RoutingUITests ONLY: Settings -> Flight Control against the routing fixture.
#
# Runs on the UI-test Mac through scripts/smoke-remote.sh, never on this Mac's screen. That
# script builds here, syncs the products, takes the remote lock and its 120 s run-rate cap
# (FLIGHTDECK_TEST_THROTTLE), and writes the result bundle and log to DerivedData/smoke-remote/.
# This wrapper only supplies the selection and the gate: the test skips without it, and ssh
# carries no environment, so smoke-remote.sh bakes every TEST_RUNNER_* into the xctestrun it
# ships. The suite is not part of the smoke gate; run once, never in a loop.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="DerivedData/smoke-remote"
SHOTS="DerivedData/routing-ui-shots"
rm -rf "$SHOTS"

set +e
FD_UITEST_ONLY="FlightDeckUITests/RoutingUITests" TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1 ./scripts/smoke-remote.sh
rc=$?
set -e

# smoke-remote.sh copies the result bundle back; the screenshots are its attachments.
if [ -d "$OUT/run.xcresult" ] && xcrun xcresulttool export attachments --path "$OUT/run.xcresult" --output-path "$SHOTS" >/dev/null 2>&1; then
  echo "[routing-ui] screenshots -> $SHOTS"
else
  echo "[routing-ui] no screenshots exported; result bundle: $OUT/run.xcresult"
fi

if [ "$rc" -ne 0 ]; then echo "ROUTING UI FAIL (rc=$rc) — see scripts/.smoke.log"; exit "$rc"; fi
echo "ROUTING UI PASS"
