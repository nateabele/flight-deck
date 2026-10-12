#!/usr/bin/env bash
# Build Flight Deck for distribution outside the App Store: archive, export with Developer ID,
# notarize, staple, and package as a zip and a dmg in dist/.
#
#   scripts/release.sh                 full pipeline
#   scripts/release.sh --no-notarize   stop after the Developer ID export (signing check only)
#
# Notarization reads stored notarytool credentials from the login keychain, under the profile
# named by NOTARY_PROFILE (default `developer-id-notary`). Create it once with:
#
#   xcrun notarytool store-credentials developer-id-notary \
#     --key ~/.appstoreconnect/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
#
# Certificates and provisioning are automatic: `-allowProvisioningUpdates` lets xcodebuild
# create the Developer ID Application certificate through the Xcode account if it is missing.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Xcode's export runs /usr/bin/rsync, whose remote end resolves `rsync` through PATH; a
# Homebrew rsync 3.x there rejects Apple's `-E` and fails the export with "Copy failed".
export PATH="/usr/bin:$PATH"
cd "$(dirname "$0")/.."

TEAM_ID=ZM74LQ6QWG
NOTARY_PROFILE="${NOTARY_PROFILE:-developer-id-notary}"
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    *) echo "usage: $(basename "$0") [--no-notarize]" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)"
OUT="dist/$VERSION"
ARCHIVE="$OUT/FlightDeck.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Flight Deck.app"
ZIP="$OUT/Flight Deck-$VERSION.zip"
DMG="$OUT/Flight Deck-$VERSION.dmg"

if [ "$NOTARIZE" = 1 ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "no usable notarytool profile '$NOTARY_PROFILE' in the keychain (see the header of this script)" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> archiving $VERSION"
xcodegen generate -q
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { tail -30 "$OUT/archive.log"; exit 1; }

echo "==> exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { tail -30 "$OUT/export.log"; exit 1; }

echo "==> checking signatures"
codesign --verify --strict --deep "$APP"
# Every Mach-O in the bundle must carry Developer ID and a secure timestamp, and every
# executable the hardened runtime, or notarization rejects the whole submission. Libraries
# need no runtime flag of their own: they run under their host process's.
bad=0
while IFS= read -r -d '' f; do
  kind="$(file -b "$f")"
  grep -q 'Mach-O' <<<"$kind" || continue
  info="$(codesign -dv --verbose=2 "$f" 2>&1)"
  if ! grep -q 'Authority=Developer ID Application' <<<"$info" \
     || { grep -q 'executable' <<<"$kind" && ! grep -q 'flags=.*runtime' <<<"$info"; } \
     || ! grep -q '^Timestamp=' <<<"$info"; then
    echo "  not distributable: ${f#"$APP/"}" >&2
    bad=1
  fi
done < <(find "$APP" -type f -print0)
[ "$bad" = 0 ] || exit 1

if [ "$NOTARIZE" = 0 ]; then
  echo "Exported (not notarized): $APP"
  exit 0
fi

echo "==> notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
  | tee "$OUT/notarize.log"
grep -q 'status: Accepted' "$OUT/notarize.log" || { echo "notarization was not accepted" >&2; exit 1; }
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Flight Deck.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Flight Deck" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
# The app export can use Xcode's cloud-managed Developer ID, which leaves no identity in the
# keychain; the dmg can only be signed with a local one (Xcode → Settings → Apple Accounts →
# Manage Certificates → + Developer ID Application). Unsigned, it is still notarized and
# stapled, and the app inside carries its own signature and ticket.
# By hash: a name match would be ambiguous if another team's Developer ID is in the keychain.
DEVID="$(security find-identity -v -p codesigning | awk -v t="($TEAM_ID)" '/Developer ID Application/ && index($0, t) {print $2; exit}')"
if [ -n "$DEVID" ]; then
  codesign --sign "$DEVID" --timestamp "$DMG"
else
  echo "  (no local Developer ID Application identity: dmg left unsigned)"
fi
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee -a "$OUT/notarize.log"
xcrun stapler staple "$DMG"
[ -z "$DEVID" ] || spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Released $VERSION:"
echo "  $ZIP"
echo "  $DMG"
