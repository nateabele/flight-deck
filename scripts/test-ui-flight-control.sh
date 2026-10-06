#!/usr/bin/env bash
# Runs SwarmUITests against the Flight Control fixture backend (L3-S Task 14), on the UI-test Mac
# through scripts/smoke-remote.sh. Never looped: smoke-remote.sh holds the remote lock and a
# 120 s run-rate cap, and the run launches Flight Deck (Debug) on the UI-test Mac's screen.
#
# Touches no live state: -FlightDeckResetState gives preferences a nil persistence,
# -FlightDeckFixture redirects sessions/status/transcripts and replaces the login shell with a
# stub agent (no `claude` ever runs), -FlightControlFixtureBackend points am/br at stubs, and
# -FlightDeckDaemonDir keeps the fixture's fd-abduco daemons apart from every real one.
#
# Why the fixture is built ON the UI-test Mac: scripts/make-flight-control-fixture.py bakes absolute paths into
# sessions.json and the stubs, and the test only receives the fixture's path through
# TEST_RUNNER_FLIGHT_CONTROL_FIXTURE / _SEEDED / _DAEMONS. A fixture built here would name
# directories that do not exist on the UI-test Mac. So this script rsyncs the generator and its captured
# inputs to the UI-test Mac, runs it there, and passes the UI-test Mac's absolute paths. Both live OUTSIDE smoke-remote.sh's
# products tree, because its `rsync --delete` of DerivedData/Build/Products would remove them.
# The generator needs python3 on the UI-test Mac (the stubs are python3/bash too).
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${FD_UITEST_HOST:-user@uitest-mac}
KEY=${FD_UITEST_SSH_KEY:-$HOME/.ssh/id_rsa}
SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 -i "$KEY")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"
REMOTE_DIR=flightdeck-uitests
GEN="$REMOTE_DIR/fc-gen"
CAPTURED="Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm"
OUT="DerivedData/smoke-remote"
SHOTS="DerivedData/flight-control-ui"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"

# The remote login shell is fish: every remote command is bash fed on stdin.
remote() { ssh "${SSH_OPTS[@]}" "$HOST" bash -s -- "$@"; }

if ! REMOTE_HOME=$(remote <<<'echo "$HOME"'); then
  echo "FLIGHT CONTROL UI FAIL: UI-test host $HOST is unreachable"
  exit 2
fi
# Short, because a daemon socket is <dir>/<uuid>.sock and macOS caps sun_path at 104 bytes.
# Both fixtures' tabs share it (the cases run one at a time).
DAEMONS=$(remote <<<'echo "/tmp/fdfc-ui-$(id -u)"')
ROOT="$REMOTE_HOME/$REMOTE_DIR/DerivedData/fc-fixture"

reap_remote() {
  # The fixture's tabs run under detached daemons that outlive the app; reap them by path. The
  # paths are expanded HERE, into the script text, never passed as arguments: `pkill -f` matches
  # full command lines, so a `bash -s -- <path>` carrying the path would kill itself.
  remote >/dev/null 2>&1 <<REMOTE || true
pkill -f "$DAEMONS" 2>/dev/null
pkill -f "$ROOT" 2>/dev/null
rm -rf "$DAEMONS"
exit 0
REMOTE
}
trap reap_remote EXIT

reap_remote
remote <<REMOTE
set -e
rm -rf "$GEN"
mkdir -p "$GEN/scripts" "$GEN/$CAPTURED" "$DAEMONS"
REMOTE
rsync -a -e "$RSYNC_SSH" scripts/make-flight-control-fixture.py "$HOST:$GEN/scripts/"
if [ -d "$CAPTURED" ]; then rsync -a --delete -e "$RSYNC_SSH" "$CAPTURED/" "$HOST:$GEN/$CAPTURED/"; fi
remote <<REMOTE
set -e
cd "$GEN"
python3 scripts/make-flight-control-fixture.py "$ROOT/live"
python3 scripts/make-flight-control-fixture.py "$ROOT/seeded" --seeded
REMOTE

set +e
FD_UITEST_ONLY="FlightDeckUITests/SwarmUITests" \
  TEST_RUNNER_FLIGHT_CONTROL_DAEMONS="$DAEMONS" \
  TEST_RUNNER_FLIGHT_CONTROL_FIXTURE="$ROOT/live" \
  TEST_RUNNER_FLIGHT_CONTROL_SEEDED="$ROOT/seeded" \
  ./scripts/smoke-remote.sh
rc=$?
set -e

xcrun xcresulttool export attachments --path "$OUT/run.xcresult" --output-path "$SHOTS" >/dev/null 2>&1 || true
rsync -a -e "$RSYNC_SSH" "$HOST:$REMOTE_DIR/DerivedData/fc-fixture/live/stub.log" "$SHOTS/stub.log" >/dev/null 2>&1 || true
echo "[flight-control-ui] screenshots and stub log -> $SHOTS"

if [ "$rc" -ne 0 ]; then
  echo "FLIGHT CONTROL UI FAIL (rc=$rc) — see scripts/.smoke.log"
  exit "$rc"
fi
echo "FLIGHT CONTROL UI PASS"
