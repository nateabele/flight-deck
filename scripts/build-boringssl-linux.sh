#!/usr/bin/env bash
# scripts/build-boringssl-linux.sh — libcrypto.a from the pinned vendor/boringssl for the
# Linux hostd's SPAKE2. Separate from swift-nio-ssl's own vendored copy (whose symbols are
# CNIOBoringSSL_-prefixed), so the two link side by side without clashing.
#
# Usage: ./scripts/build-boringssl-linux.sh [x86_64|aarch64]   (default: this machine's arch)
# Output: vendor/boringssl-artifacts/linux-<arch>/libcrypto.a, git-ignored like the rest of
# vendor/boringssl-artifacts. Run once per checkout before scripts/test-hostd-linux-interop.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${1:-$(uname -m | sed 's/arm64/aarch64/')}
PLATFORM=$([ "$ARCH" = x86_64 ] && echo linux/amd64 || echo linux/arm64)
mkdir -p "vendor/boringssl-artifacts/linux-$ARCH"
# Resolved, and mounted on its own: in a worktree vendor/boringssl-artifacts is a symlink to
# the main checkout's (AGENTS.md, worktree setup), and a symlink pointing outside the `/src`
# bind mount dangles inside the container — the copy below would fail on a path that exists.
OUT=$(cd "vendor/boringssl-artifacts/linux-$ARCH" && pwd -P)
docker run --rm --platform "$PLATFORM" -v "$PWD:/src" -v "$OUT:/out" -w /src swift:6.3-noble bash -c "
  apt-get update -qq && apt-get install -y -qq cmake ninja-build golang >/dev/null &&
  cmake -S vendor/boringssl -B /tmp/b -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON &&
  ninja -C /tmp/b crypto && cp /tmp/b/libcrypto.a /out/"
ls -l "vendor/boringssl-artifacts/linux-$ARCH/libcrypto.a"
