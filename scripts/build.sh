#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -configuration Debug \
  -derivedDataPath DerivedData build
echo "Built: DerivedData/Build/Products/Debug/FlightDeck.app"
