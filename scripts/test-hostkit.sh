#!/usr/bin/env bash
# scripts/test-hostkit.sh — HostKit's tests on macOS, then in swift:6.3-noble.
set -euo pipefail
cd "$(dirname "$0")/../Packages/HostKit"
swift test
docker run --rm -v "$PWD:/src" -w /src swift:6.3-noble swift test --scratch-path /tmp/hk
