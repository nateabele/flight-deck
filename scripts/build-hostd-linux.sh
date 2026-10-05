#!/usr/bin/env bash
# scripts/build-hostd-linux.sh — the Linux hostd release assets, in build/hostd-release/:
#   flightdeck-hostd-linux-<arch>.tar.gz   one static-stdlib binary per architecture
#   hostd-install.sh                       the installer, with this release's URL baked in
#   SHA256SUMS                             the digest of every asset above
#   installer.xcconfig                     FD_HOSTD_INSTALLER_SHA256 (the digest of SHA256SUMS)
#                                          for the Release app build to embed
#
# Usage: ./scripts/build-hostd-linux.sh [aarch64|x86_64 ...]   (default: both)
# Builds in swift:6.3-noble under Docker; x86_64 runs emulated on Apple silicon and is slow.
# Publishing the assets as a GitHub release is a separate, manual step — nothing here uploads.
#
# FD_HOSTD_RELEASE_BASE_URL overrides where the installer and the app look for the assets.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHES=("$@")
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(aarch64 x86_64)

# The release tag follows the app's MARKETING_VERSION, read from project.yml (its source of
# truth) so the URL baked into the installer here and the one Xcode expands into the app's
# Info.plist cannot name two different releases.
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)
[ "$(printf '%s\n' "$VERSION" | grep -c .)" = 1 ] ||
  { echo "expected exactly one MARKETING_VERSION in project.yml, got: $VERSION" >&2; exit 1; }
BASE=${FD_HOSTD_RELEASE_BASE_URL:-https://github.com/nateabele/flight-deck/releases/download/hostd-v$VERSION}

OUT=build/hostd-release
# Emptied first so SHA256SUMS can only list what this run built: a tarball left over from an
# earlier run of other sources would otherwise be signed into the release beside the new one.
rm -rf "$OUT"
mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd -P)
for ARCH in "${ARCHES[@]}"; do
  case "$ARCH" in
    aarch64) PLATFORM=linux/arm64 ;;
    x86_64) PLATFORM=linux/amd64 ;;
    *) echo "unknown arch $ARCH (aarch64 or x86_64)" >&2; exit 64 ;;
  esac
  # A pinned submodule, so an archive already built from it is current; rebuilding it costs
  # minutes per architecture (more under emulation) for the same bytes.
  [ -f "vendor/boringssl-artifacts/linux-$ARCH/libcrypto.a" ] || ./scripts/build-boringssl-linux.sh "$ARCH"
  # Mounted at its resolved path, as in test-hostd-linux.sh: in a worktree the artifacts
  # directory is a symlink that dangles inside the container otherwise.
  ARTIFACTS=$(cd vendor/boringssl-artifacts && pwd -P)
  # A scratch path per architecture, apart from the debug .build the test scripts share: the
  # two architectures' manifests and build databases would otherwise overwrite each other.
  # The tarball is made inside the container because macOS tar adds AppleDouble `._` entries.
  docker run --rm --platform "$PLATFORM" -v "$PWD:/src" -v "$ARTIFACTS:$ARTIFACTS" -v "$OUT_ABS:/out" \
    -w /src/Packages/HostDaemonLinux swift:6.3-noble bash -euo pipefail -c "
      SCRATCH=.build/release-$ARCH
      swift build -c release --static-swift-stdlib --product HostDaemonLinux --scratch-path \$SCRATCH
      STAGE=\$(mktemp -d)
      cp \"\$(swift build -c release --static-swift-stdlib --scratch-path \$SCRATCH --show-bin-path)/HostDaemonLinux\" \$STAGE/flightdeck-hostd
      strip \$STAGE/flightdeck-hostd
      tar -C \$STAGE --owner=0 --group=0 -czf /out/flightdeck-hostd-linux-$ARCH.tar.gz flightdeck-hostd"
done

sed "s|@FD_HOSTD_ASSET_BASE@|$BASE|" scripts/hostd-install.sh > "$OUT/hostd-install.sh"
(cd "$OUT" && shasum -a 256 flightdeck-hostd-linux-*.tar.gz hostd-install.sh > SHA256SUMS)
DIGEST=$(shasum -a 256 "$OUT/SHA256SUMS" | cut -d' ' -f1)

# Included (optionally) by Resources/HostdRelease.xcconfig, so the next Release build of the
# app shows a command whose digest matches exactly these assets. `//` starts a comment in an
# xcconfig, hence the `$()` that splits the scheme's slashes without changing the value.
cat > "$OUT/installer.xcconfig" <<EOF
// Written by scripts/build-hostd-linux.sh for the assets beside it. Do not edit.
FD_HOSTD_RELEASE_BASE_URL = ${BASE/:\/\//:/\$()/}
FD_HOSTD_INSTALLER_SHA256 = $DIGEST
EOF

cat "$OUT/SHA256SUMS"
echo "SHA256SUMS digest: $DIGEST"
echo "release base: $BASE"
[ ${#ARCHES[@]} -eq 2 ] || echo "note: built ${ARCHES[*]} only — not a complete release"
