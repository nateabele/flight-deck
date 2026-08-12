#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Regenerates the AppIcon image set from the master artwork.
#
# The master (assets/appicon-source.png) is a 1226x1226 full-bleed rounded-rect
# ("squircle") with transparent corners. It is used AS-IS, edge to edge, with no
# manual inset — that is deliberate and was verified empirically on macOS 26:
#
#   * macOS draws app icons inset to ~80.5% of the canvas (the classic 824-in-1024
#     grid) and adds the drop shadow ITSELF. Pre-insetting the artwork here would
#     compound the two and render the icon at ~65% — visibly smaller than every
#     neighbouring icon in the Dock.
#   * The system also normalises icon-shaped artwork to Apple's canonical squircle.
#     Rendering this icon through NSWorkspace produced an alpha silhouette
#     pixel-identical (0 differing pixels of 65536) to natively-adopted icons such
#     as Terminal and Blender.
#   * Artwork WITHOUT transparent corners is treated as legacy content instead:
#     macOS shrinks it further and parks it on a light backing plate. So the
#     transparent corners in the master are load-bearing — do not flatten them
#     onto an opaque background.
#
# Requires ImageMagick (`brew install imagemagick`).

SRC=assets/appicon-source.png
OUT=Sources/FlightDeck/Assets.xcassets/AppIcon.appiconset

command -v magick >/dev/null || { echo "error: ImageMagick not found (brew install imagemagick)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "error: master artwork not found at $SRC" >&2; exit 1; }

# 16/32/64/128/256/512/1024 cover all ten @1x/@2x slots in Contents.json
# (several sizes are referenced by two slots, e.g. 32 is 16x16@2x and 32x32@1x).
for s in 16 32 64 128 256 512 1024; do
  magick "$SRC" -filter Lanczos -resize "${s}x${s}" -strip "$OUT/icon_${s}.png"
  echo "  wrote $OUT/icon_${s}.png"
done

echo "AppIcon regenerated from $SRC"
