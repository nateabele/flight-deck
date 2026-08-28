#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Build, install, and RELAUNCH the phone app on a real device.
#
# The relaunch is the point. `devicectl device install app` replaces the bundle and leaves
# whatever was running as the OLD code, or leaves nothing running at all — so every install
# was followed by picking the phone up and tapping the icon, and more than once by reading a
# stale build's behaviour and believing it.
#
# DEVICE may be a name, UDID, or ECID; the name is used by default because it survives the
# cable coming and going. Transport is CoreDevice's problem, not ours: with wireless
# debugging enabled this runs over Wi-Fi (`transportType: localNetwork`) and over USB
# otherwise, with no change here.
DEVICE="${DEVICE:-Mobile3}"
BUNDLE_ID="dev.flightdeck.FlightDeckMobile"
APP="DerivedData/Build/Products/Debug-iphoneos/FlightDeckMobile.app"

# `generic/platform=iOS` rather than `id=<udid>`, deliberately. A concrete destination makes
# xcodebuild resolve the device BEFORE compiling, so a phone that is asleep or momentarily off
# the network fails the build rather than the install — thirty seconds of work thrown away for
# a step that had not started yet. The generic destination builds the same arm64 slice.
if [ "${1:-}" != "--no-build" ]; then
  echo "==> building"
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath DerivedData -allowProvisioningUpdates build \
    | tail -1
fi

echo "==> installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" \
  | grep -E 'installationURL|App installed' || true

# `--terminate-existing` because the old process survives the install and would otherwise keep
# running the previous bundle — the exact stale-build read this script exists to prevent.
#
# NO `--console`, and that is not an oversight. `--console` ties the app's lifetime to this
# command: when the command ends, the app is killed. Used casually it produces a phone that
# dies the moment a script finishes, which on this project once looked like a networking bug
# (a connection stuck in SYN_RCVD) that was really just the app being terminated mid-handshake.
# To watch output, run the launch yourself with --console and leave it in the foreground.
# A locked phone installs fine and refuses to launch, which is the ordinary case when the
# handset is face-down on a desk. That is not a failure of the deploy — the new build IS on
# the device — so it is reported as the one sentence it is rather than as a stack of
# FBSOpenApplicationErrorDomain, and the script still exits 0.
echo "==> relaunching"
if ! launch_out=$(xcrun devicectl device process launch \
    --device "$DEVICE" --terminate-existing "$BUNDLE_ID" 2>&1); then
  if printf '%s' "$launch_out" | grep -q "could not be, unlocked"; then
    echo "    installed, but NOT relaunched: the device is locked. Unlock it and open the app,"
    echo "    or re-run this script."
  else
    printf '%s\n' "$launch_out" | tail -4
    exit 1
  fi
else
  printf '%s\n' "$launch_out" | grep -E 'Launched' || true
fi
