#!/usr/bin/env bash
# scripts/test-hostd-linux.sh — Packages/HostDaemonLinux's own tests, in swift:6.3-noble.
# Linux only: the package links the pinned BoringSSL's Linux libcrypto, so it does not build
# for macOS. Prerequisite: ./scripts/build-boringssl-linux.sh
#
# Uses the package's own .build, the one test-hostd-linux-interop.sh builds into, so a run
# after an interop run starts warm instead of rebuilding SwiftNIO from cold.
set -euo pipefail
cd "$(dirname "$0")/.."
# Mounted at its resolved path too, for the reason test-hostd-linux-interop.sh gives: in a
# worktree vendor/boringssl-artifacts is a symlink that dangles inside the container otherwise.
ARTIFACTS=$(cd vendor/boringssl-artifacts && pwd -P)
docker run --rm -v "$PWD:/src" -v "$ARTIFACTS:$ARTIFACTS" -w /src/Packages/HostDaemonLinux \
  swift:6.3-noble swift test "$@"
