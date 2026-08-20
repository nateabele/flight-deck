#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Compile-only check of the iOS slice of FleetKit, and of the FlightDeckMobile app that
# links it.
#
# There is no iOS Simulator runtime installed on this machine and no provisioning profile,
# so nothing here can be RUN — but it can be built, and building is the whole point: this
# is what fails when FleetKit's shared sources acquire a macOS-only import, or when
# FlightDeckMobile stops linking FleetKit for iOS. `-scheme` rather than `-target`: this
# Xcode (26.6) rejects `-derivedDataPath` on a plain `-target` build with "The flag
# -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath"
# — and every xcodebuild invocation in this repo is expected to pass -derivedDataPath.
# Both `FleetKitiOS` and `FlightDeckMobile` therefore have a scheme declared explicitly in
# project.yml's `schemes:` block, written to disk by `xcodegen generate` below as a real
# shared .xcscheme — not left to xcodebuild's own implicit, unpersisted scheme synthesis
# for a buildable target, which is exactly the undocumented fallback this script would
# otherwise be silently depending on.
xcodegen generate
for scheme in FleetKitiOS FlightDeckMobile; do
  xcodebuild -project FlightDeck.xcodeproj -scheme "$scheme" \
    -configuration Debug -sdk iphonesimulator \
    -derivedDataPath DerivedData build
done
