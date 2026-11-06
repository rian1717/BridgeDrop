#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and checksum a release DMG.
#
# Required:
#   BRIDGEDROP_SIGN_IDENTITY="Developer ID Application: …"
#   BRIDGEDROP_NOTARY_PROFILE="notarytool-keychain-profile"
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"
APP="$APP_DIR/build/BridgeDrop.app"
DMG="$APP_DIR/build/BridgeDrop-macOS.dmg"

: "${BRIDGEDROP_SIGN_IDENTITY:?Set BRIDGEDROP_SIGN_IDENTITY to a Developer ID Application identity}"
: "${BRIDGEDROP_NOTARY_PROFILE:?Set BRIDGEDROP_NOTARY_PROFILE to a notarytool keychain profile}"

"$HERE/build-app.sh" release

echo "▶︎ Signing app with hardened runtime…"
codesign --force --options runtime --timestamp \
  --entitlements "$APP_DIR/../BridgeDropShareExtension/BridgeDropShareExtension.entitlements" \
  --sign "$BRIDGEDROP_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/BridgeDropShareExtension.appex"
codesign --force --options runtime --timestamp \
  --sign "$BRIDGEDROP_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Creating DMG…"
BRIDGEDROP_SKIP_BUILD=1 "$HERE/make-dmg.sh" release

echo "▶︎ Signing DMG…"
codesign --force --timestamp --sign "$BRIDGEDROP_SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "▶︎ Submitting to Apple notarization…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$BRIDGEDROP_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "✓ Release ready:"
echo "  $DMG"
echo "  $DMG.sha256"
