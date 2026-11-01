#!/usr/bin/env bash
# scripts/build-fdindex.sh — builds `fdindex` (Packages/FlightIndex), the machine-wide code index's
# one binary (daemon, MCP shim and query CLI), into the git-ignored vendor/fdindex-artifacts/fdindex.
#
# Run by Xcode as the FlightDeck target's pre-build script (project.yml), which then copies and
# signs the artifact into `Contents/MacOS/fdindex` beside `flightdeck`, and runnable by hand. Always
# `cargo build --release`: the Debug app embeds the same optimised binary, because the index's speed
# is the point and an unoptimised tree-sitter build is not a fair stand-in. Cargo's own incremental
# build makes a second run a no-op (about a quarter of a second), and the artifact is rewritten only
# when its bytes change, so Xcode's Copy Files phase does not see a new file every build.
#
# Architectures follow the app's ARCHS (arm64 unless the project says otherwise); two of them are
# joined with lipo. The environment is scrubbed first: Xcode exports SDKROOT, ARCHS, deployment
# targets and a CC wrapper that the `cc` crate (sqlite, tree-sitter) would otherwise pick up.
#
# FD_FDINDEX_DRY_RUN=1 prints what it would do and builds nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=Packages/FlightIndex
OUT=vendor/fdindex-artifacts
DEV=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ARCH_LIST=${ARCHS:-arm64}
# `ARCHS` may name only what Xcode is building right now ("arm64 x86_64" or just one of them).
case " $ARCH_LIST " in *" arm64 "*) ;; *" x86_64 "*) ;; *) ARCH_LIST=arm64 ;; esac

triple() { case "$1" in arm64) echo aarch64-apple-darwin ;; x86_64) echo x86_64-apple-darwin ;; esac; }

# Xcode's script PATH has neither rustup's nor Homebrew's bin.
CARGO_PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cargo_bin=$(PATH="$CARGO_PATH" command -v cargo || true)

if [ -z "$cargo_bin" ]; then
  if [ -f "$OUT/fdindex" ]; then
    echo "warning: cargo not found; embedding the existing $OUT/fdindex as is" >&2
    exit 0
  fi
  echo "error: cargo not found, and there is no $OUT/fdindex. Install Rust (brew install rust or rustup) to build the code index." >&2
  exit 1
fi

if [ "${FD_FDINDEX_DRY_RUN:-}" = 1 ]; then
  for a in $ARCH_LIST; do
    echo "would run: cargo build --release --locked --target $(triple "$a") --manifest-path $PKG/Cargo.toml"
  done
  echo "would write: $OUT/fdindex ($ARCH_LIST)"
  exit 0
fi

built=()
for a in $ARCH_LIST; do
  t=$(triple "$a")
  env -i HOME="$HOME" PATH="$CARGO_PATH" DEVELOPER_DIR="$DEV" MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$cargo_bin" build --release --locked --quiet --target "$t" --manifest-path "$PKG/Cargo.toml"
  built+=("$PKG/target/$t/release/fdindex")
done

mkdir -p "$OUT"
tmp=$(mktemp "$OUT/.fdindex.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if [ "${#built[@]}" -gt 1 ]; then
  lipo -create "${built[@]}" -output "$tmp"
else
  cp "${built[0]}" "$tmp"
fi
chmod 755 "$tmp"
if [ -f "$OUT/fdindex" ] && cmp -s "$tmp" "$OUT/fdindex"; then
  echo "fdindex is up to date ($OUT/fdindex)"
else
  mv "$tmp" "$OUT/fdindex"
  echo "built $OUT/fdindex ($ARCH_LIST)"
fi
