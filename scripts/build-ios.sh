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
# So the BUILD is skipped rather than failed — loudly, never silently, and the skip still
# type-checks the sources (see below). Failing outright would make the script useless as a
# gate for the work that CAN be checked here, and that is most of it: the phone's wire types,
# keychain record and connection logic all live in FleetKit precisely so they are covered on
# this machine by the build above. Only the SwiftUI screens fall back to the type-check, and
# they are unverifiable beyond that anyway without a simulator to render them.
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
  # Matching xcodebuild's own destination-resolution wording, which is the fragile part
  # of this script: it is not API, and a future Xcode may reword it. It fails safe — a
  # reworded message stops matching, falls to the `else` branch, and the script fails
  # loudly rather than skipping something it should not have skipped.
  if grep -qE 'Found no destinations|is not installed' "$IOS_LOG"; then
    rm -f "$IOS_LOG"

    # A skip that verified nothing would rot: every SwiftUI screen added to this target
    # from here on would go unchecked indefinitely, and the first person to learn that
    # would be whoever finally installs the iOS platform. So when the app cannot be
    # BUILT, its sources are at least TYPE-CHECKED against the framework just built
    # above. That is strictly less than a build — no linking, no Info.plist processing,
    # no signing, no SwiftUI runtime wiring — but it does catch the failure that actually
    # happens while writing this code: source that does not compile.
    #
    # `-I .../Modules` rather than `-F`: the framework is FleetKitiOS.framework but the
    # module inside it is FleetKit, and `-F` searches by *framework* name, so it would
    # report "no such module 'FleetKit'" and look like a broken import.
    # `-parse-as-library` because @main is an error in a file the compiler treats as a
    # script, which is how it treats these when they are passed directly.
    # The triple's iOS version tracks `options.deploymentTarget.iOS` in project.yml.
    echo
    echo "== SKIPPED: FlightDeckMobile build ==========================================="
    echo "   The iOS platform is not installed, so an app target has no destination to"
    echo "   build for. Falling back to a type-check of its sources."
    echo "   Install with: xcodebuild -downloadPlatform iOS"
    echo "==============================================================================="
    xcrun --sdk iphonesimulator swiftc -typecheck -parse-as-library \
      -swift-version 6 \
      -target "$(uname -m)-apple-ios17.0-simulator" \
      -I DerivedData/Build/Products/Debug-iphonesimulator/FleetKitiOS.framework/Modules \
      Sources/FlightDeckMobile/*.swift
    echo "** FlightDeckMobile TYPE-CHECK PASSED (build skipped, see above) **"
    echo
  else
    # A real compile error, not a missing platform. Surface it and fail.
    cat "$IOS_LOG"
    rm -f "$IOS_LOG"
    exit 1
  fi
fi
