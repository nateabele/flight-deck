#!/usr/bin/env bash
set -euo pipefail

# Build libghostty (GhosttyKit.xcframework) from the vendored `vendor/ghostty`
# submodule and stage the result at `vendor/ghostty-artifacts/`.
#
# --- Why this script exists in this form -----------------------------------
#
# Ghostty (vendor/ghostty) pins `.minimum_zig_version = "0.15.2"` in
# build.zig.zon, and its build.zig enforces an EXACT major.minor match (see
# src/build/zig.zig's requireZig()) -- a Zig 0.16.x toolchain is rejected at
# comptime with "Your Zig version v0.16.0 does not meet the required build
# version of v0.15.2". So this script downloads/manages its own Zig 0.15.2,
# independent of whatever `zig` is on PATH (e.g. a Homebrew-installed 0.16.0),
# under the git-ignored `vendor/.zig-toolchain/`.
#
# Separately, on macOS hosts with Xcode 26.4+ / the 26.x macOS SDK, Zig
# 0.15.2's Mach-O linker mis-parses the newer SDK's libSystem.tbd and fails
# to link ANY native binary -- even a trivial `zig build-exe` hello-world --
# with dozens of "undefined symbol" errors for basic libSystem functions
# (_abort, _bzero, __availability_version_check, ...). This is a known,
# already-reported upstream Zig bug: ziglang/zig#31658 ("MacOS Builds Are
# Failing w/ XCode 26.4"), https://codeberg.org/ziglang/zig/issues/31658.
# The fix (PR #31673) targets the 0.16.0 milestone; there is no confirmed
# 0.15.x patch release with the backport as of this writing, and Ghostty
# does not (yet) accept Zig 0.16.
#
# WORKAROUND (this script's approach): redirect only
# `xcrun --show-sdk-path ...macosx...` lookups to the older MacOSX15.4 SDK
# (still present under the Command Line Tools' SDKs/ directory on hosts that
# have accumulated multiple SDK versions), via a thin `xcrun` shim placed
# first on PATH. Zig 0.15.2 then links against the older (correctly-parsed)
# SDK's libSystem.tbd, while `DEVELOPER_DIR` still points at the real, full
# Xcode install, so real frameworks (AppKit, Metal, etc.) are still found
# and linked correctly.
#
# IMPORTANT: `DEVELOPER_DIR=/dev/null` (an earlier idea to dodge the SDK
# entirely) does NOT work for this build -- it hides the frameworks
# libghostty links against (AppKit, CoreText, Metal, ...), so the build
# fails differently (missing frameworks) rather than succeeding. The
# MacOSX15.4-SDK xcrun-shim below is the approach that actually produces a
# working GhosttyKit.xcframework.
#
# This script is idempotent: re-running it re-downloads nothing that's
# already present and verified, rebuilds libghostty, re-stages the
# artifact, and leaves the submodule pinned-clean afterward.

# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
# FD_GHOSTTY_ARTIFACTS_DIR stages somewhere else, to check a build before replacing the one in use.
ARTIFACTS_DIR="${FD_GHOSTTY_ARTIFACTS_DIR:-$REPO_ROOT/vendor/ghostty-artifacts}"
ZIG_TOOLCHAIN_DIR="$REPO_ROOT/vendor/.zig-toolchain"
ZIG_VERSION="0.15.2"
ZIG_TARBALL="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
ZIG_BIN="$ZIG_TOOLCHAIN_DIR/zig-aarch64-macos-${ZIG_VERSION}/zig"
SHIM_DIR="$REPO_ROOT/vendor/.build-shim"
SDK_154="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

# --- Step 1: ensure the Zig 0.15.2 toolchain is present ---------------------

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "==> Downloading Zig ${ZIG_VERSION} (aarch64-macos)..."
  mkdir -p "$ZIG_TOOLCHAIN_DIR"
  curl -sL -o "$ZIG_TOOLCHAIN_DIR/$ZIG_TARBALL" "$ZIG_URL"
  echo "==> Verifying checksum..."
  echo "${ZIG_SHA256}  $ZIG_TOOLCHAIN_DIR/$ZIG_TARBALL" | shasum -a 256 -c -
  echo "==> Extracting..."
  tar xf "$ZIG_TOOLCHAIN_DIR/$ZIG_TARBALL" -C "$ZIG_TOOLCHAIN_DIR"
fi

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "error: expected Zig binary not found at $ZIG_BIN after setup" >&2
  exit 1
fi

# --- Step 2: create the xcrun SDK-redirect shim -----------------------------

if [[ ! -d "$SDK_154" ]]; then
  echo "error: required MacOSX15.4 SDK not found at $SDK_154" >&2
  echo "       This host does not have the older SDK needed to work around" >&2
  echo "       ziglang/zig#31658. See docs/TOOLING.md for details and" >&2
  echo "       alternative unblock options." >&2
  exit 1
fi

mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/xcrun" <<'SHIM_EOF'
#!/usr/bin/env bash
# Shim: force the older MacOSX15.4 SDK for macosx --show-sdk-path lookups,
# to sidestep Zig 0.15.2's Mach-O linker mis-parsing the newer SDK's
# libSystem.tbd (ziglang/zig#31658). Everything else passes through to the
# real /usr/bin/xcrun untouched, so frameworks still resolve against the
# real (full) Xcode install via DEVELOPER_DIR.
args="$*"
if [[ "$args" == *"--show-sdk-path"* && "$args" == *"macosx"* ]]; then
  echo "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  exit 0
fi
exec /usr/bin/xcrun "$@"
SHIM_EOF
chmod +x "$SHIM_DIR/xcrun"

# --- Step 3: build libghostty -----------------------------------------------

echo "==> Building libghostty (GhosttyKit.xcframework)..."
# Start from a clean submodule: a run that failed part-way leaves a .zig-cache whose half-built
# pieces a later run links into an incomplete libghostty-fat.a without any error.
git -C "$GHOSTTY_DIR" clean -xdfq
(
  cd "$GHOSTTY_DIR"
  # -Doptimize is REQUIRED. Zig's `standardOptimizeOption` defaults to Debug when
  # the flag is absent, and Ghostty maps Debug -> `slow_runtime_safety = true`
  # (src/build/Config.zig). That turns on `PageList.assertIntegrity`, which runs a
  # full `Page.verifyIntegrity` walk on every cell write. Profiling a Debug build
  # showed reflow spending 81% of its time (850 of 1052 samples) inside
  # verifyIntegrity -- and because reflow holds the surface mutex on the io thread,
  # the main thread blocked for ~1s at a time in mouse handlers, beach-balling the
  # app. ReleaseFast is what upstream ships.
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    PATH="$SHIM_DIR:$PATH" \
    "$ZIG_BIN" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
)

# --- Step 4: stage the artifact out of the submodule ------------------------

if [[ ! -d "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" ]]; then
  echo "error: build did not produce macos/GhosttyKit.xcframework" >&2
  exit 1
fi

# An incomplete fat archive still "builds"; it fails only when the app links. Count the API.
api=$(nm -g "$GHOSTTY_DIR/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a" 2>/dev/null | grep -c ' T _ghostty_' || true)
if [[ "$api" -lt 50 ]]; then
  echo "error: libghostty-fat.a exports only $api _ghostty_ symbols; the build is incomplete" >&2
  exit 1
fi

# Zig compiles its fetched dependencies (highway, among others) out of ~/.cache/zig, and this
# checkout's own sources from under $REPO_ROOT, so __FILE__ strings and debug info name the
# builder's home folder. Overwrite those prefixes in place with neutral text of the same length:
# offsets inside each object stay put, so the archive is otherwise byte-for-byte what Zig wrote.
# (Pointing Zig at another cache with --global-cache-dir instead builds a libghostty-fat.a that
# silently lacks most of its members.)
python3 - "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$HOME/.cache/zig/" "$REPO_ROOT/" <<'PY'
import os, sys
root, *prefixes = sys.argv[1:]
subs = [(p.encode(), (("/" * (len(p) - len("build/"))) + "build/").encode()) for p in prefixes]
for dirpath, _, files in os.walk(root):
    for name in files:
        if not name.endswith(".a"):
            continue
        path = os.path.join(dirpath, name)
        data = open(path, "rb").read()
        new = data
        for old, rep in subs:
            new = new.replace(old, rep)
        if new != data:
            open(path, "wb").write(new)
PY

mkdir -p "$ARTIFACTS_DIR"
rm -rf "$ARTIFACTS_DIR/GhosttyKit.xcframework"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$ARTIFACTS_DIR/"

# --- Step 5: leave the submodule pinned-clean -------------------------------

git -C "$GHOSTTY_DIR" clean -xdf

echo "==> libghostty artifacts staged at vendor/ghostty-artifacts/GhosttyKit.xcframework"
