#!/usr/bin/env bash
# Tests/fd-abduco/run_all.sh — aggregate runner: build, unit trim of the
# output-log helper, baseline create/list/exit roundtrip, replay, the
# ATTACH/RESIZE race regression, and budget-trim, in one shot.
#
# `cd "$(dirname "$0")"` first so this works regardless of the caller's cwd
# (repo root, this directory, or anywhere else) and regardless of whether it
# is invoked as `bash Tests/fd-abduco/run_all.sh`, `./run_all.sh`, or via a
# relative/absolute path to the script itself.
set -euo pipefail
cd "$(dirname "$0")"
bash run_outlog_test.sh
bash baseline_smoke.sh
bash run_replay_test.sh
bash run_replay_busy_test.sh
bash run_trim_test.sh
echo "ALL fd-abduco tests OK"
