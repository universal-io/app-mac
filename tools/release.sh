#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, and package Universal I/O as a DMG for
# direct, outside-App-Store distribution.
#
# Distribution uses the PAID Apple Developer team TG68TFXG88 (see ~/AGENTS.md
# "Apple Developer Accounts"). The Release configuration in project.yml already
# selects the "Developer ID Application" cert and enables Hardened Runtime.
#
# One-time setup before first run (store notary credentials in the keychain):
#   xcrun notarytool store-credentials universal-io-notary \
#     --apple-id <your-apple-id-email> \
#     --team-id TG68TFXG88 \
#     --password <app-specific-password>   # from appleid.apple.com
#
# Usage:  bash tools/release.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SCHEME="BombSquad"
CONFIG="Release"
APP_NAME="Universal IO"
TEAM_ID="TG68TFXG88"
NOTARY_PROFILE="${NOTARY_PROFILE:-universal-io-notary}"

# Optional R2 upload. Set R2_ENDPOINT / R2_BUCKET / R2_PROFILE in
# tools/release.env (gitignored) to auto-upload the notarized DMG. Credentials
# live in the aws CLI profile, not here. Absent config = build only.
[[ -f "$PROJECT_ROOT/tools/release.env" ]] && source "$PROJECT_ROOT/tools/release.env"

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/${SCHEME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$PROJECT_ROOT/dist"
LOCAL_PLIST="$PROJECT_ROOT/BombSquad.local.plist"
LOCAL_PLIST_BACKUP="$BUILD_DIR/BombSquad.local.plist.bak"

# Always restore the developer's local.plist (localhost gateway), even on error.
restore_local_plist() {
  if [[ -f "$LOCAL_PLIST_BACKUP" ]]; then
    cp "$LOCAL_PLIST_BACKUP" "$LOCAL_PLIST"
    echo "-> restored BombSquad.local.plist (dev localhost)"
  fi
}
trap restore_local_plist EXIT

echo "== preflight =="
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "ERROR: no 'Developer ID Application' cert in keychain."; exit 1; }
command -v xcodegen >/dev/null \
  || { echo "ERROR: xcodegen not installed (brew install xcodegen)."; exit 1; }
# SKIP_NOTARIZE=1 builds + signs + packages but skips the Apple round-trip.
# Use it to validate signing/Hardened Runtime before notary creds exist. The
# resulting DMG will NOT pass Gatekeeper on other machines (not for release).
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "ERROR: notarytool profile '$NOTARY_PROFILE' not found. Run once:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "    --apple-id <your-apple-id-email> --team-id $TEAM_ID \\"
    echo "    --password <app-specific-password>"
    exit 1
  }
else
  echo "-> SKIP_NOTARIZE set: build/sign/package only (not a releasable DMG)"
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# 1. Point the distribution build at the production gateway. local.plist is
#    bundled and read first, so blank its API base URL to fall back to
#    Info.plist's https://api.universal-io.com. Supabase URL/anon key stay
#    (public client key, identical in production).
if [[ -f "$LOCAL_PLIST" ]]; then
  cp "$LOCAL_PLIST" "$LOCAL_PLIST_BACKUP"
  /usr/libexec/PlistBuddy -c "Set :BOMB_SQUAD_API_BASE_URL ''" "$LOCAL_PLIST"
  echo "-> blanked BOMB_SQUAD_API_BASE_URL for release (prod fallback)"
fi

echo "== xcodegen generate =="
xcodegen generate

echo "== archive (Release) =="
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project BombSquad.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  -quiet
[[ -d "$ARCHIVE_PATH" ]] || { echo "ERROR: archive not produced."; exit 1; }

echo "== export (Developer ID) =="
EXPORT_OPTS="$BUILD_DIR/export-options.plist"
cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: exported app not found at $APP_PATH"; exit 1; }

echo "== verify signature =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "audio-input" \
  && echo "-> microphone entitlement present" || echo "WARN: audio-input entitlement missing"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  echo "== notarize app =="
  APP_ZIP="$BUILD_DIR/$APP_NAME.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/Universal-IO-$VERSION.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
echo "== build DMG (v$VERSION) =="
rm -rf "$DMG_STAGING"; mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  echo "== notarize DMG =="
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
else
  echo "== SKIP_NOTARIZE: DMG built but not notarized/stapled =="
fi

# Upload to R2 only for a real (notarized) release with config present.
if [[ -z "${SKIP_NOTARIZE:-}" && -n "${R2_ENDPOINT:-}" && -n "${R2_BUCKET:-}" ]]; then
  echo "== upload to R2 =="
  CT="application/x-apple-diskimage"
  aws s3 cp "$DMG_PATH" "s3://${R2_BUCKET}/Universal-IO-$VERSION.dmg" \
    --profile "${R2_PROFILE:-r2}" --endpoint-url "$R2_ENDPOINT" --content-type "$CT"
  aws s3 cp "$DMG_PATH" "s3://${R2_BUCKET}/Universal-IO.dmg" \
    --profile "${R2_PROFILE:-r2}" --endpoint-url "$R2_ENDPOINT" --content-type "$CT"
  echo "-> uploaded: Universal-IO-$VERSION.dmg and Universal-IO.dmg (latest)"
  echo "-> https://dl.universal-io.com/Universal-IO.dmg"
fi

echo ""
echo "Done: $DMG_PATH"
