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
# Usage:
#   bash tools/release.sh             # build/notarize only
#   bash tools/release.sh --publish   # build/notarize and publish to R2
set -euo pipefail

PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  -h|--help)
    sed -n '1,17p' "$0"
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument '$1' (use --publish or --help)."
    exit 2
    ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SCHEME="BombSquad"
CONFIG="Release"
APP_NAME="Universal IO"
TEAM_ID="TG68TFXG88"
NOTARY_PROFILE="${NOTARY_PROFILE:-universal-io-notary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"

# R2 credentials are loaded only for an explicit --publish run. Credentials live
# in the aws CLI profile, while the endpoint/bucket/profile live in the
# gitignored tools/release.env.
if [[ "$PUBLISH" -eq 1 ]]; then
  [[ -f "$PROJECT_ROOT/tools/release.env" ]] \
    || { echo "ERROR: tools/release.env is required for --publish."; exit 1; }
  source "$PROJECT_ROOT/tools/release.env"
fi

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/${SCHEME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$PROJECT_ROOT/dist"

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
if [[ "$PUBLISH" -eq 1 ]]; then
  [[ -z "${SKIP_NOTARIZE:-}" ]] \
    || { echo "ERROR: --publish cannot be combined with SKIP_NOTARIZE."; exit 1; }
  command -v aws >/dev/null \
    || { echo "ERROR: aws CLI is required for --publish."; exit 1; }
  [[ -n "${R2_ENDPOINT:-}" && -n "${R2_BUCKET:-}" ]] \
    || { echo "ERROR: R2_ENDPOINT and R2_BUCKET are required for --publish."; exit 1; }
  aws s3api head-bucket --bucket "$R2_BUCKET" \
    --profile "${R2_PROFILE:-r2}" --endpoint-url "$R2_ENDPOINT" >/dev/null
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

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
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/Universal-IO-$VERSION-build$BUILD_NUMBER.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
echo "== build DMG (v$VERSION build $BUILD_NUMBER) =="
rm -rf "$DMG_STAGING"; mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

echo "== sign DMG (Developer ID) =="
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  echo "== notarize DMG =="
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
else
  echo "== SKIP_NOTARIZE: DMG built but not notarized/stapled =="
fi

# Publishing is deliberately separate from ordinary release builds. The release
# path is immutable; the version and latest aliases are the only replaceable
# objects used by the website and older links.
if [[ "$PUBLISH" -eq 1 ]]; then
  echo "== upload to R2 =="
  CT="application/x-apple-diskimage"
  SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  SOURCE_COMMIT="$(git rev-parse HEAD)"
  OBJECT_METADATA="sha256=$SHA256,version=$VERSION,build=$BUILD_NUMBER,commit=$SOURCE_COMMIT"
  R2_ARGS=(--profile "${R2_PROFILE:-r2}" --endpoint-url "$R2_ENDPOINT")
  RELEASE_KEY="releases/$VERSION/build-$BUILD_NUMBER/Universal-IO.dmg"
  VERSION_KEY="Universal-IO-$VERSION.dmg"
  LATEST_KEY="Universal-IO.dmg"

  if aws s3api head-object --bucket "$R2_BUCKET" --key "$RELEASE_KEY" \
    "${R2_ARGS[@]}" >/dev/null 2>&1; then
    REMOTE_SHA256="$(aws s3api head-object --bucket "$R2_BUCKET" --key "$RELEASE_KEY" \
      "${R2_ARGS[@]}" --query 'Metadata.sha256' --output text)"
    [[ "$REMOTE_SHA256" == "$SHA256" ]] || {
      echo "ERROR: immutable release exists with different content: s3://${R2_BUCKET}/${RELEASE_KEY}"
      exit 1
    }
    echo "-> immutable release already contains this exact DMG; resuming alias updates"
  else
    aws s3 cp "$DMG_PATH" "s3://${R2_BUCKET}/${RELEASE_KEY}" \
      "${R2_ARGS[@]}" --content-type "$CT" --metadata "$OBJECT_METADATA" \
      --cache-control "public,max-age=31536000,immutable"
  fi
  aws s3 cp "$DMG_PATH" "s3://${R2_BUCKET}/${VERSION_KEY}" \
    "${R2_ARGS[@]}" --content-type "$CT" --metadata "$OBJECT_METADATA" \
    --cache-control "public,max-age=300"
  aws s3 cp "$DMG_PATH" "s3://${R2_BUCKET}/${LATEST_KEY}" \
    "${R2_ARGS[@]}" --content-type "$CT" --metadata "$OBJECT_METADATA" \
    --cache-control "public,max-age=300"

  echo "-> immutable: https://dl.universal-io.com/$RELEASE_KEY"
  echo "-> version:   https://dl.universal-io.com/$VERSION_KEY"
  echo "-> latest:    https://dl.universal-io.com/Universal-IO.dmg"
  echo "-> sha256:    $SHA256"
fi

echo ""
echo "Done: $DMG_PATH"
