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

# Flags, order-independent:
#   --release    build (and install) Release instead of Debug
#   --no-build   install whatever is already in the products dir
#
# Debug is the default because this script is the inner loop of phone work, and Release costs
# whole-module optimisation on every run for a build nobody is going to attach a debugger to.
# `--release` exists for the other case: putting a build on the handset to LIVE with, where
# Debug's un-optimised binary is the wrong thing to judge scrolling and launch time by.
#
# Signing does not change between the two. `project.yml` pins CODE_SIGN_IDENTITY[sdk=iphoneos*]
# to `Apple Development` and the team to 2T9E3N27J8 for both configurations, so `--release`
# still produces a development-signed build for THIS device — it is not a distribution build
# and will not install anywhere else.
CONFIG=Debug
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --release)  CONFIG=Release ;;
    --no-build) BUILD=0 ;;
    *) echo "usage: $(basename "$0") [--release] [--no-build]" >&2; exit 2 ;;
  esac
done

# Derived from CONFIG, never hardcoded: `--no-build --release` reads a DIFFERENT products
# directory, and the failure when those two disagree is silent — devicectl installs a stale
# Debug bundle and reports success, which is the same stale-build read the relaunch below
# exists to prevent.
APP="DerivedData/Build/Products/$CONFIG-iphoneos/FlightDeckMobile.app"

# `generic/platform=iOS` rather than `id=<udid>`, deliberately. A concrete destination makes
# xcodebuild resolve the device BEFORE compiling, so a phone that is asleep or momentarily off
# the network fails the build rather than the install — thirty seconds of work thrown away for
# a step that had not started yet. The generic destination builds the same arm64 slice.
if [ "$BUILD" = 1 ]; then
  echo "==> building $CONFIG"
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
    -configuration "$CONFIG" -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath DerivedData -allowProvisioningUpdates build \
    | tail -1
fi

# Checked after the build rather than before, so a missing bundle names the real cause: with
# --no-build it means "you never built this configuration", not "the build failed".
if [ ! -d "$APP" ]; then
  echo "no $CONFIG bundle at $APP" >&2
  [ "$BUILD" = 0 ] && echo "  (--no-build was passed; drop it, or build $CONFIG first)" >&2
  exit 1
fi

echo "==> installing $CONFIG on $DEVICE"
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
