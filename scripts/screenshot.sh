#!/usr/bin/env bash
# Regenerates the README screenshot.
#
# Deliberately NOT part of scripts/smoke.sh. This drives a real app launch, which seizes the
# foreground for the length of the run — fine to opt into, not fine to pay on every suite.
#
# Touches no live state at all, which is stronger than the smoke gate manages:
#
#  - `-FlightDeckResetState` gives the preferences store a nil persistence, so `preferences.v1`
#    is neither read nor written.
#  - `-FlightDeckFixture` redirects all three of the app's roots at a throwaway directory —
#    the session snapshot, the status registry that would otherwise be `~/.claude/sessions`,
#    and the transcript tree that would otherwise be `~/.claude/projects`.
#  - The fixture's own shell replaces the login shell, so no `claude` is ever spawned.
#  - Unlike smoke.sh this deletes no `NSWindow Frame` defaults by default, so the developer's
#    saved window geometry is left alone.
#
# That last point has one consequence worth knowing. Screenshotting the window *element* means
# where the window sits cannot affect the framing — but it does affect the resolution, because
# the capture inherits the backing scale of whatever display the window opens on. A window
# restored onto a 1x external monitor yields a 1x image; centred on the built-in retina panel
# it yields 2x. Pass `--center` to delete the geometry keys first (exactly as smoke.sh does)
# and force the window onto the primary display for a reproducible 2x capture.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

CENTER=0
if [ "${1:-}" = "--center" ]; then
  CENTER=1
  shift
fi

OUT="${1:-$PWD/assets/screenshot.png}"
mkdir -p "$(dirname "$OUT")"

# Opt-in only: this discards the developer's saved window position. Deleting ONLY the geometry
# keys, never the whole domain — that would take `sessions.snapshot.v1` and `preferences.v1`
# with it, i.e. every real session and preference on the machine.
if [ "$CENTER" -eq 1 ]; then
  for key in \
    "NSWindow Frame main" \
    "NSSplitView Subview Frames main, SidebarNavigationSplitView"
  do
    defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
  done
  echo "→ window geometry cleared; capture will centre on the primary display"
fi

# `sources:` in project.yml is a directory glob resolved at generation time, so a newly added
# test file is invisible to xcodebuild until this runs. Same first step as build.sh/test-unit.sh.
xcodegen generate

RESULTS="$PWD/DerivedData/screenshot.xcresult"
FIXTURE="$PWD/DerivedData/screenshot-fixture"
rm -rf "$RESULTS"

# Built here rather than in the test: the UI-test bundle is sandboxed and can write only to
# its own container, which the app cannot read. See the header of the script below.
echo "→ building fixture"
python3 scripts/make-screenshot-fixture.py "$FIXTURE"

echo "→ capturing"
TEST_RUNNER_FLIGHT_DECK_FIXTURE="$FIXTURE" \
xcodebuild test \
  -project FlightDeck.xcodeproj \
  -scheme FlightDeck \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$RESULTS" \
  -only-testing:FlightDeckUITests/ScreenshotTests/testCaptureReadmeScreenshot \
  2>&1 | tail -5

# The test cannot write into the repo: the UI-test bundle runs inside the xctrunner sandbox
# and gets "Operation not permitted" for any path under the project. It attaches the image
# instead, and this exports it — xcodebuild is not sandboxed, so it can.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
xcrun xcresulttool export attachments \
  --path "$RESULTS" \
  --output-path "$STAGE" \
  --test-id "ScreenshotTests/testCaptureReadmeScreenshot()" >/dev/null 2>&1

# Pick the attachment by its declared name rather than by file extension: a failed run also
# attaches a screen recording and a diagnostic PNG, and grabbing one of those would silently
# publish a picture of the failure.
SHOT="$(python3 - "$STAGE" <<'PY'
import json, os, sys
stage = sys.argv[1]
manifest = os.path.join(stage, "manifest.json")
if not os.path.exists(manifest):
    sys.exit(0)
with open(manifest) as handle:
    entries = json.load(handle)
def walk(node):
    if isinstance(node, dict):
        if node.get("suggestedHumanReadableName", "").startswith("flight-deck"):
            print(os.path.join(stage, node["exportedFileName"]))
            raise SystemExit(0)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(entries)
PY
)"

if [ -z "$SHOT" ] || [ ! -f "$SHOT" ]; then
  echo "✗ no 'flight-deck' attachment in $RESULTS — did the test fail before the shutter?" >&2
  exit 1
fi

cp "$SHOT" "$OUT"
echo "✓ $(du -h "$OUT" | cut -f1)  $OUT"
