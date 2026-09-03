#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The venv lives OUTSIDE the repo, matching scripts/livefuzz/README.md's rule.
VENV=/tmp/adapterprobe-venv
if [ ! -x "$VENV/bin/python" ]; then
  echo "[adapterprobe] creating $VENV…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet pyte
fi

# Same output discipline as smoke.sh: xcodebuild is thousands of lines and floods a
# transcript. Full build output goes to the log; the matrix goes to stdout.
LOG="scripts/.adapterprobe.log"
: > "$LOG"
echo "[adapterprobe] building probe… (full output → $LOG)"
if ! scripts/adapterprobe/build-probe.sh >>"$LOG" 2>&1; then
  echo "ADAPTERPROBE FAIL: probe build failed — see $LOG"; tail -n 30 "$LOG"; exit 1
fi

exec "$VENV/bin/python" scripts/adapterprobe/run.py "$@"
