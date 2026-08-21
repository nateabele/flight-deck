#!/usr/bin/env bash
set -euo pipefail
# Not optional, and this script was the one place in scripts/ that omitted it: this
# machine's `xcode-select -p` is /Library/Developer/CommandLineTools, where
# `xcrun --sdk iphoneos --show-sdk-path` fails outright ("SDK iphoneos cannot be located").
# CMAKE_OSX_SYSROOT=iphoneos then cannot resolve, and -create-xcframework refuses with
# "requires Xcode". The artifact is git-ignored and built only from here, so a script that
# fails on the repo's own machine means nobody can build the dependency at all.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Build BoringSSL's libcrypto from the vendored `vendor/boringssl` submodule as a
# three-slice xcframework, and stage the result at `vendor/boringssl-artifacts/` --
# exactly the arrangement scripts/build-libghostty.sh uses for GhosttyKit.
#
# FleetKit uses one thing out of it: SPAKE2, the password-authenticated key exchange behind
# the short pairing code. SPAKE2 is not separable from libcrypto upstream, so the whole
# static library comes along. Nothing is forked -- upstream is a submodule, and this script
# is the entire relationship with it.
#
# The artifact is NOT committed (see .gitignore); the submodule commit is. Run this after a
# fresh clone, or after moving the submodule pin.
#
# Needs cmake, ninja and go on PATH (`brew install cmake ninja go`). BoringSSL generates
# part of its build with Go; there is no way around it and no reason to want one.

SRC="$(pwd)/vendor/boringssl"
OUT="vendor/boringssl-artifacts"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

# The submodule commit is the pin. This tag is kept so that the commit message, this script
# and the staged VERSION file all name the same thing in a form a human can check against
# upstream's release list -- a bare SHA is auditable only by someone who already has the
# repo. It is verified below rather than trusted: a submodule quietly moved off the reviewed
# tag is exactly the drift a vendored security dependency must not have.
BORINGSSL_TAG="0.20250114.0"

if [[ ! -e "$SRC/CMakeLists.txt" ]]; then
  echo "error: vendor/boringssl is empty -- the submodule is not checked out." >&2
  echo "       Run: git submodule update --init vendor/boringssl" >&2
  exit 1
fi

ACTUAL_TAG="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
if [[ "$ACTUAL_TAG" != "$BORINGSSL_TAG" ]]; then
  echo "error: vendor/boringssl is checked out at '${ACTUAL_TAG:-no tag}', not $BORINGSSL_TAG." >&2
  echo "       This is a vendored security dependency; move the pin deliberately, in its" >&2
  echo "       own commit, updating BORINGSSL_TAG here in the same commit." >&2
  exit 1
fi

# CMAKE_SYSTEM_NAME, not just a sysroot: without it CMake treats an iphoneos build as a
# native Darwin one and runs its compiler probes against the host, which is how a slice ends
# up quietly configured for the wrong platform. And the deployment target goes through
# CMAKE_OSX_DEPLOYMENT_TARGET rather than a hand-written `-m*-version-min` in CMAKE_C_FLAGS,
# because BoringSSL's crypto sources are C++ (.cc) as of this tag -- a C-only flag would
# miss nearly all of them.
#
# CMAKE_MACOSX_BUNDLE=OFF is load-bearing for the two iOS slices and a no-op for macOS:
# under CMAKE_SYSTEM_NAME=iOS, CMake defaults every executable to MACOSX_BUNDLE, and
# BoringSSL's `install(TARGETS bssl ...)` then fails to CONFIGURE with "given no BUNDLE
# DESTINATION for MACOSX_BUNDLE executable target". We never build or install `bssl` -- only
# `crypto` -- but install rules are evaluated at configure time regardless.
#
# Builds go to $WORK, never into the submodule, so the submodule is left pinned-clean
# without needing the `git clean -xdf` that build-libghostty.sh has to do.
build_slice() {
  local name="$1" system="$2" sysroot="$3" arch="$4" deploy="$5"
  cmake -S "$SRC" -B "$WORK/build-$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DBUILD_SHARED_LIBS=OFF
  cmake --build "$WORK/build-$name" --target crypto
}

# The deployment targets track `options.deploymentTarget` in project.yml.
build_slice macos  Darwin macosx          arm64          14.0
build_slice ios    iOS    iphoneos        arm64          17.0
build_slice iossim iOS    iphonesimulator "arm64;x86_64" 17.0

rm -rf "$OUT"
mkdir -p "$OUT"

# Headers are identical across slices, so they are staged ONCE here rather than passed to
# `-create-xcframework -headers`.
#
# That is not a tidiness preference, it is the only thing that works. Xcode resolves a
# library xcframework's `-headers` by copying them into BUILT_PRODUCTS_DIR/include -- the
# same directory libghostty already populates, and that directory contains libghostty's
# `module.modulemap` declaring `module GhosttyKit { umbrella header "ghostty.h" }`. An
# umbrella header claims every header in its directory for its module, so `openssl/*.h`
# landing there becomes part of GhosttyKit. `#include <openssl/curve25519.h>` then resolves
# to `@import GhosttyKit`, whose umbrella does not include it, and every SPAKE2 declaration
# is silently dropped: the shim module builds clean and Swift reports "cannot find
# 'SPAKE2_CTX_new' in scope". Keeping the headers out of that directory entirely is what
# avoids it; targets reach them through HEADER_SEARCH_PATHS on this path instead.
mkdir -p "$OUT/include"
cp -R "$SRC/include/openssl" "$OUT/include/openssl"

xcodebuild -create-xcframework \
  -library "$WORK/build-macos/libcrypto.a" \
  -library "$WORK/build-ios/libcrypto.a" \
  -library "$WORK/build-iossim/libcrypto.a" \
  -output "$OUT/BoringSSL.xcframework"

# Record what produced the artifact next to it. The artifact is git-ignored, so this is what
# tells you whether the tree in front of you was built from the pin you are reading.
cat > "$OUT/VERSION" <<EOF
BoringSSL $BORINGSSL_TAG
$(git -C "$SRC" rev-parse HEAD)
Built by scripts/build-boringssl.sh from the vendor/boringssl submodule
EOF

echo "Built $OUT/BoringSSL.xcframework from BoringSSL $BORINGSSL_TAG"
