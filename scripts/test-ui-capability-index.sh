#!/usr/bin/env bash
# Runs CapabilityIndexUITests (Flight Control L3-I) on the UI-test Mac through
# scripts/smoke-remote.sh, and exports its screenshots to DerivedData/capability-index-ui-shots.
#
# The test reads its fixture folder (Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui) by a
# path derived from #filePath, which is this checkout's path and does not exist on the UI-test Mac. So the
# folder is rsynced to the UI-test Mac first, OUTSIDE smoke-remote.sh's products tree (its `rsync --delete`
# would remove it there), and its remote absolute path is handed to the test as
# INDEX_UI_FIXTURE. The gate is TEST_RUNNER_INDEX_UI=1; ssh carries no environment, so
# smoke-remote.sh bakes both variables into the xctestrun it ships.
# Run once, never in a loop: smoke-remote.sh holds the remote lock and a 120 s run-rate cap.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib-local-env.sh
fd_load_local_env
# No default host: the UI-test Mac is machine-specific and must never be written into a committed
# file. Without this check an empty host fails later as an opaque ssh usage error.
if [ -z "${FD_UITEST_HOST:-}" ]; then
  echo "CAPABILITY INDEX UI FAIL: no UI-test host configured."
  echo "            cp scripts/local.env.example scripts/local.env and set FD_UITEST_HOST"
  echo "            (and FD_UITEST_SSH_KEY if ssh needs an explicit identity file)."
  exit 2
fi

HOST=$FD_UITEST_HOST
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
# IdentitiesOnly with an explicit key: an agent holding many keys otherwise exhausts the server's
# auth attempts before offering the right one. Without a key, ssh's own defaults apply.
[ -n "${FD_UITEST_SSH_KEY:-}" ] && SSH_OPTS+=(-o IdentitiesOnly=yes -i "$FD_UITEST_SSH_KEY")
SRC="Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui"
REMOTE_REL="flightdeck-uitests/index-fixture"
OUT="DerivedData/smoke-remote"
SHOTS="DerivedData/capability-index-ui-shots"
rm -rf "$SHOTS"

# The remote login shell is fish: every remote command is bash fed on stdin.
if ! REMOTE_HOME=$(ssh "${SSH_OPTS[@]}" "$HOST" bash -s <<<'echo "$HOME"'); then
  echo "CAPABILITY INDEX UI FAIL: UI-test host $HOST is unreachable"
  exit 2
fi
ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$REMOTE_REL" <<<'mkdir -p "$HOME/$1"'
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "$SRC/" "$HOST:$REMOTE_REL/"

set +e
FD_UITEST_ONLY="FlightDeckUITests/CapabilityIndexUITests" \
  TEST_RUNNER_INDEX_UI=1 TEST_RUNNER_INDEX_UI_FIXTURE="$REMOTE_HOME/$REMOTE_REL" \
  ./scripts/smoke-remote.sh
rc=$?
set -e

if [ -d "$OUT/run.xcresult" ] && xcrun xcresulttool export attachments --path "$OUT/run.xcresult" --output-path "$SHOTS" >/dev/null 2>&1; then
  echo "[capability-index-ui] screenshots -> $SHOTS"
else
  echo "[capability-index-ui] no screenshots exported; result bundle: $OUT/run.xcresult"
fi

if [ "$rc" -ne 0 ]; then echo "CAPABILITY INDEX UI FAIL (rc=$rc) — see scripts/.smoke.log"; exit "$rc"; fi
echo "CAPABILITY INDEX UI PASS"
