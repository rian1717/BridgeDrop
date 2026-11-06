#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and checksum a release DMG.
#
# Required:
#   KERNPORT_SIGN_IDENTITY="Developer ID Application: …"
#   KERNPORT_NOTARY_PROFILE="notarytool-keychain-profile"
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"
APP="$APP_DIR/build/KERNPORT.app"
DMG="$APP_DIR/build/KERNPORT-macOS.dmg"

: "${KERNPORT_SIGN_IDENTITY:?Set KERNPORT_SIGN_IDENTITY to a Developer ID Application identity}"
: "${KERNPORT_NOTARY_PROFILE:?Set KERNPORT_NOTARY_PROFILE to a notarytool keychain profile}"

"$HERE/build-app.sh" release

echo "▶︎ Signing app with hardened runtime…"
codesign --force --options runtime --timestamp \
  --entitlements "$APP_DIR/../BridgeDropShareExtension/BridgeDropShareExtension.entitlements" \
  --sign "$KERNPORT_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/BridgeDropShareExtension.appex"
codesign --force --options runtime --timestamp \
  --sign "$KERNPORT_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Creating DMG…"
KERNPORT_SKIP_BUILD=1 "$HERE/make-dmg.sh" release

echo "▶︎ Signing DMG…"
codesign --force --timestamp --sign "$KERNPORT_SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "▶︎ Submitting to Apple notarization…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$KERNPORT_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "✓ Release ready:"
echo "  $DMG"
echo "  $DMG.sha256"
