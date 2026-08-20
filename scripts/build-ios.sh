#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Compile-only check of everything that targets iOS.
#
# Nothing here is RUN — that needs a booted simulator, and docs/MOBILE.md has the sequence —
# but building is the whole point: this is what fails when FleetKit's shared sources acquire
# a macOS-only import, which is the boundary the two-platform split exists to enforce.
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
# even for `build` alone. That needs an iOS platform installed. On a machine that has one
# this is a real build and the branch below never runs; on a machine that does not, no
# destination — simulator or generic device — can be resolved at all.
#
# So on such a machine the BUILD is skipped rather than failed — loudly, never silently, and
# the skip still type-checks the sources (see below). Failing outright would make the script
# useless as a gate for the work that CAN be checked here, and that is most of it: the
# phone's wire types, keychain record and connection logic all live in FleetKit precisely so
# they are covered everywhere by the build above.
#
# To turn a skip into a real check: Xcode > Settings > Components, or
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
    # `-F` over the products directory, which works only because FleetKitiOS now sets
    # PRODUCT_NAME as well as PRODUCT_MODULE_NAME: the product is FleetKit.framework and
    # the module inside it is FleetKit, so framework search — which matches by *framework*
    # name — resolves `import FleetKit`. While the two disagreed this had to reach past the
    # framework with `-I .../FleetKitiOS.framework/Modules`, and that workaround is exactly
    # why nobody noticed the app target could not link the framework at all.
    #
    # This fallback is strictly weaker than a build in one way worth naming: region-based
    # isolation ("sending '…' risks causing data races") is a SIL pass, and `-typecheck`
    # never reaches SIL. Swift 6 concurrency errors in these sources pass here and fail a
    # real build. Treat a green type-check as "it parses and the types line up", no more.
    #
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
      -F DerivedData/Build/Products/Debug-iphonesimulator \
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
