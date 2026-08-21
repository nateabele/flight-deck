#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build BoringSSL's libcrypto as a three-slice xcframework and stage it at
# `vendor/boringssl-artifacts/`. FleetKit uses exactly one thing out of it — SPAKE2, the
# password-authenticated key exchange behind the short pairing code — but SPAKE2 is not
# separable from libcrypto upstream, so the whole static library comes along. Nothing is
# forked: this script is the entire relationship with the dependency.
#
# Unlike scripts/build-libghostty.sh, the OUTPUT of this script is committed. Ghostty's
# artifact is git-ignored and rebuilt from a submodule; there is no BoringSSL submodule,
# so the .xcframework in vendor/boringssl-artifacts is the checked-in source of truth and
# re-running this is only needed when BORINGSSL_TAG moves.
#
# Needs cmake, ninja and go on PATH (`brew install cmake ninja go`). BoringSSL generates
# part of its build with Go; there is no way around it and no reason to want one.

# Pinned rather than tracking master: this is a vendored security dependency, and
# "whatever HEAD was the day someone re-ran this" is not a version anyone can audit.
# Update deliberately, in its own commit, with the tag in the message.
BORINGSSL_TAG="${BORINGSSL_TAG:-0.20250114.0}"
WORK="$(mktemp -d)"
OUT="vendor/boringssl-artifacts"

trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 --branch "$BORINGSSL_TAG" \
  https://boringssl.googlesource.com/boringssl "$WORK/src"

# CMAKE_SYSTEM_NAME, not just a sysroot: without it CMake treats an iphoneos build as a
# native Darwin one and runs its compiler probes against the host, which is how a slice
# ends up quietly configured for the wrong platform. And the deployment target goes
# through CMAKE_OSX_DEPLOYMENT_TARGET rather than a hand-written `-m*-version-min` in
# CMAKE_C_FLAGS, because BoringSSL's crypto sources are C++ (.cc) as of this tag — a C-only
# flag would miss nearly all of them.
#
# CMAKE_MACOSX_BUNDLE=OFF is load-bearing for the two iOS slices and a no-op for macOS:
# under CMAKE_SYSTEM_NAME=iOS, CMake defaults every executable to MACOSX_BUNDLE, and
# BoringSSL's `install(TARGETS bssl ...)` then fails to CONFIGURE with "given no BUNDLE
# DESTINATION for MACOSX_BUNDLE executable target". We never build or install `bssl` — only
# `crypto` — but the install rule is evaluated at configure time regardless.
build_slice() {
  local name="$1" system="$2" sysroot="$3" arch="$4" deploy="$5"
  cmake -S "$WORK/src" -B "$WORK/build-$name" -G Ninja \
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
# library xcframework's `-headers` by copying them into BUILT_PRODUCTS_DIR/include — the
# same directory libghostty already populates, and that directory contains libghostty's
# `module.modulemap` declaring `module GhosttyKit { umbrella header "ghostty.h" }`. An
# umbrella header claims every header in its directory for its module, so `openssl/*.h`
# landing there becomes part of GhosttyKit. `#include <openssl/curve25519.h>` then resolves
# to `@import GhosttyKit`, whose umbrella does not include it, and every SPAKE2 declaration
# is silently dropped: the shim module builds clean and Swift reports "cannot find
# 'SPAKE2_CTX_new' in scope". Keeping the headers out of that directory entirely is what
# avoids it; targets reach them through HEADER_SEARCH_PATHS on this path instead.
mkdir -p "$OUT/include"
cp -R "$WORK/src/include/openssl" "$OUT/include/openssl"

xcodebuild -create-xcframework \
  -library "$WORK/build-macos/libcrypto.a" \
  -library "$WORK/build-ios/libcrypto.a" \
  -library "$WORK/build-iossim/libcrypto.a" \
  -output "$OUT/BoringSSL.xcframework"

# Record what produced the artifact next to it: the .xcframework is committed, so without
# this the only trace of which upstream revision it came from is a commit message that
# will scroll out of sight.
cat > "$OUT/VERSION" <<EOF
BoringSSL $BORINGSSL_TAG
$(git -C "$WORK/src" rev-parse HEAD)
Built by scripts/build-boringssl.sh
EOF

echo "Built $OUT/BoringSSL.xcframework from BoringSSL $BORINGSSL_TAG"
