#!/usr/bin/env bash
# Packages/FlightIndex/scripts/test.sh — the crate's tests: `cargo nextest run` when cargo-nextest is
# installed (a process per test, all of them in parallel: about half the wall time of `cargo test`,
# which runs the test binaries one after another), else `cargo test`. Arguments go to either
# (a test name, `--test fresh`). Install it with `cargo install cargo-nextest --locked`.
set -euo pipefail
cd "$(dirname "$0")/.."
if cargo nextest --version >/dev/null 2>&1; then
  exec cargo nextest run --no-fail-fast "$@"
fi
echo "cargo-nextest is not installed: falling back to cargo test" >&2
exec cargo test "$@"
