#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Compile-only check of the iOS slice of FleetKit.
#
# There is no iOS Simulator runtime installed on this machine and no provisioning profile,
# so nothing here can be RUN — but it can be built, and building is the whole point: this
# is what fails when FleetKit's shared sources acquire a macOS-only import. `-scheme`
# rather than `-target`: this Xcode (26.6) rejects `-derivedDataPath` on a plain
# `-target` build with "The flag -scheme, -testProductsPath, or -xctestrun is required
# when specifying -derivedDataPath" — and every xcodebuild invocation in this repo is
# expected to pass -derivedDataPath. The `FleetKitiOS` scheme is declared explicitly in
# project.yml's `schemes:` block and written to disk by `xcodegen generate` below, as a
# real shared .xcscheme — not left to xcodebuild's own implicit, unpersisted scheme
# synthesis for a buildable target, which is exactly the undocumented fallback this
# script would otherwise be silently depending on.
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FleetKitiOS \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath DerivedData build
