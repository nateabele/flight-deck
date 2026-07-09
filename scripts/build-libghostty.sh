#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../vendor/ghostty"

# Ghostty (vendor/ghostty) pins .minimum_zig_version = "0.15.2" in build.zig.zon,
# and its build.zig enforces an EXACT major.minor match (see src/build/zig.zig,
# requireZig()) -- a Zig 0.16.x toolchain will fail comptime with:
#   "Your Zig version v0.16.0 does not meet the required build version of v0.15.2"
#
# As of this writing (2026-07), a Zig 0.15.2 toolchain built and installed
# via Homebrew on this host reports 0.16.0, so a separate 0.15.2 toolchain
# was downloaded (NOT via brew) and extracted to vendor/.zig-toolchain/. Set
# ZIG to that binary's path, or export ZIG in your shell before invoking this
# script, e.g.:
#   ZIG=/path/to/flight-deck/vendor/.zig-toolchain/zig-aarch64-macos-0.15.2/zig \
#     ./scripts/build-libghostty.sh
ZIG="${ZIG:-zig}"

# KNOWN BLOCKER (as of 2026-07-09, see docs/TOOLING.md): on this host
# (macOS 26.5.1 / Xcode 26.6 / Command Line Tools 26.6), Zig 0.15.1 and
# 0.15.2 fail to link ANY native binary -- even `zig build-exe` on a
# trivial hello-world -- with errors like:
#   error: undefined symbol: _abort
#   error: undefined symbol: __availability_version_check
# This is a known upstream Zig bug (ziglang/zig issue #31658, "MacOS Builds
# Are Failing w/ XCode 26.4") caused by an SDK/toolchain change in Xcode
# 26.4+. The fix landed in PR #31673 targeting the 0.16.0 milestone; there
# is no confirmed 0.15.x backport release yet. Zig 0.16.0 (e.g. via
# `brew install zig`) is NOT affected, but Ghostty's build.zig rejects
# anything that isn't exactly 0.15.x. Until either Ghostty raises its
# minimum Zig version past 0.16, or a patched/backported 0.15.x Zig release
# is available, this script cannot complete successfully on affected hosts.
# See docs/TOOLING.md for full diagnosis and workaround options.

# Build the embeddable library only (no macOS app). See macos/AGENTS.md.
"$ZIG" build -Demit-macos-app=false

# Ghostty emits the C headers + static lib under zig-out/. Locate and stage
# them. NOTE: this layout is UNVERIFIED against a real successful build on
# this host (blocked by the issue above) -- confirm/adjust these paths once
# a working Zig 0.15.2 toolchain is available.
mkdir -p ../ghostty-artifacts
cp -R zig-out/include ../ghostty-artifacts/
cp -R zig-out/lib ../ghostty-artifacts/
echo "libghostty artifacts staged in vendor/ghostty-artifacts/"
