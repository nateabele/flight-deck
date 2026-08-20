#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Compile-only check of everything that targets iOS.
#
# Nothing here can be RUN on this machine — there is no provisioning profile — but building
# is the whole point: this is what fails when FleetKit's shared sources acquire a macOS-only
# import, which is the boundary the two-platform split exists to enforce.
#
# `-scheme` rather than `-target`: Xcode 26.6 rejects `-derivedDataPath` on a plain `-target`
# build ("The flag -scheme, -testProductsPath, or -xctestrun is required when specifying
# -derivedDataPath"), and every xcodebuild invocation in this repo passes -derivedDataPath.
# Both iOS schemes are therefore declared explicitly in project.yml's `schemes:` block and
# written to disk by `xcodegen generate` as real shared .xcschemes — not left to xcodebuild's
# implicit, unpersisted scheme synthesis, which is an undocumented fallback this script would
# otherwise be silently depending on.
xcodegen generate

# FleetKitiOS is a framework, so xcodebuild compiles it from the SDK alone with no destination
# to resolve. This is the check that actually guards the module boundary, and it must pass.
xcodebuild -project FlightDeck.xcodeproj -scheme FleetKitiOS \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath DerivedData build

# FlightDeckMobile is an *application*, and an app build must resolve a concrete destination
# even for `build` alone. That needs the iOS platform installed; this machine has none
# ("iOS 26.5 is not installed"), and neither a simulator nor a generic device destination can
# be resolved without it.
#
# So this step is skipped rather than failed — loudly, never silently. Failing would make the
# script useless as a gate for the work that CAN be checked here, and everything outside
# Sources/FlightDeckMobile/ is checked by the FleetKitiOS build above: the phone's wire types,
# keychain record and connection logic all live in FleetKit precisely so they are covered on
# this machine. Only the SwiftUI screens are unverifiable, and they are unverifiable anyway
# without a simulator to render them.
#
# To turn this from a skip into a real check: Xcode > Settings > Components, or
# `xcodebuild -downloadPlatform iOS`. Then this script covers the app target too.
IOS_LOG=$(mktemp)
if xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
     -configuration Debug -sdk iphonesimulator \
     -derivedDataPath DerivedData build > "$IOS_LOG" 2>&1; then
  echo "** FlightDeckMobile BUILD SUCCEEDED **"
  rm -f "$IOS_LOG"
else
  if grep -qE 'Found no destinations|is not installed' "$IOS_LOG"; then
    echo
    echo "== SKIPPED: FlightDeckMobile =================================================="
    echo "   The iOS platform is not installed, so an app target has no destination to"
    echo "   build for. FleetKitiOS built successfully above, which covers every iOS"
    echo "   source outside Sources/FlightDeckMobile/."
    echo "   Install with: xcodebuild -downloadPlatform iOS"
    echo "==============================================================================="
    echo
    rm -f "$IOS_LOG"
  else
    # A real compile error, not a missing platform. Surface it and fail.
    cat "$IOS_LOG"
    rm -f "$IOS_LOG"
    exit 1
  fi
fi
