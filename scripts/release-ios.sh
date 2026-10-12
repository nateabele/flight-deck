#!/usr/bin/env bash
# Archive the phone app and send it to App Store Connect, where it lands in TestFlight.
#
#   scripts/release-ios.sh             archive and upload
#   scripts/release-ios.sh --no-upload archive and export an .ipa to dist/ only
#
# The upload needs an app record for io.radify.flightdeck.FlightDeckMobile in App Store Connect
# (Apps → + → New App), and an Xcode account signed in to team ZM74LQ6QWG. Each upload needs
# a build number App Store Connect has not seen: CURRENT_PROJECT_VERSION defaults to a
# timestamp here, or pass BUILD_NUMBER.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Xcode's export runs /usr/bin/rsync, whose remote end resolves `rsync` through PATH; a
# Homebrew rsync 3.x there rejects Apple's `-E` and fails the export with "Copy failed".
export PATH="/usr/bin:$PATH"
cd "$(dirname "$0")/.."

TEAM_ID=ZM74LQ6QWG
DESTINATION=upload
for arg in "$@"; do
  case "$arg" in
    --no-upload) DESTINATION=export ;;
    *) echo "usage: $(basename "$0") [--no-upload]" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUT="dist/ios-$VERSION-$BUILD_NUMBER"
ARCHIVE="$OUT/FlightDeckMobile.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> archiving $VERSION ($BUILD_NUMBER)"
xcodegen generate -q
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { tail -30 "$OUT/archive.log"; exit 1; }

echo "==> exporting for App Store Connect ($DESTINATION)"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>destination</key><string>$DESTINATION</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { tail -30 "$OUT/export.log"; exit 1; }

if [ "$DESTINATION" = upload ]; then
  echo "Uploaded $VERSION ($BUILD_NUMBER); it appears in TestFlight once App Store Connect finishes processing."
else
  echo "Exported: $(ls "$OUT"/export/*.ipa)"
fi
