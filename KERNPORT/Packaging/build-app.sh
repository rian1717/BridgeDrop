#!/usr/bin/env bash
# Build KERNPORT.app — a proper macOS bundle so the OS grants local-network
# access (Bonjour/mDNS) that a bare `swift run` binary can't get.
#
# Usage: KERNPORT/Packaging/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"                 # .../KERNPORT package
ROOT_DIR="$(dirname "$APP_DIR")"
OUT="$APP_DIR/build/KERNPORT.app"
PRODUCTS="$APP_DIR/.build/xcode-products"
OBJECTS="$APP_DIR/.build/xcode-objects"
XCODE_CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"

echo "▶︎ Building ($CONFIG)…"
xcodebuild \
  -project "$ROOT_DIR/KERNPORT.xcodeproj" \
  -target KERNPORT \
  -configuration "$XCODE_CONFIG" \
  SYMROOT="$PRODUCTS" \
  OBJROOT="$OBJECTS" \
  CODE_SIGNING_ALLOWED=NO \
  clean build >/dev/null
BUILT_APP="$PRODUCTS/$XCODE_CONFIG/KERNPORT.app"

# --- build identity -----------------------------------------------------
# A monotonic counter so it's obvious at a glance which build is running, plus
# the commit and timestamp, which are what actually pin it down. The counter
# lives outside git (it would conflict on every branch); the commit does not.
COUNTER_FILE="$HERE/.build-number"
BUILD_NUMBER=$(( $(cat "$COUNTER_FILE" 2>/dev/null || echo 34000) + 1 ))
echo "$BUILD_NUMBER" > "$COUNTER_FILE"

if GIT_COMMIT="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null)"; then
  if ! git -C "$APP_DIR" diff --quiet HEAD 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT+dirty"
  fi
else
  GIT_COMMIT="uncommitted"
fi
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

echo "▶︎ Assembling ${OUT}…"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$BUILT_APP" "$OUT"
mkdir -p "$OUT/Contents/Resources"
cp "$HERE/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

PLIST="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :KERNPORTGitCommit $GIT_COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :KERNPORTBuildDate $BUILD_DATE" "$PLIST"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
EXTENSION_PLIST="$OUT/Contents/PlugIns/KERNPORTShareExtension.appex/Contents/Info.plist"
if [[ -f "$EXTENSION_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$EXTENSION_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$EXTENSION_PLIST"
fi

# Sign the sandboxed extension first, preserving its required entitlements, then
# the containing app. `--deep` would replace the nested signature without the
# extension's sandbox entitlements and PlugInKit would reject it.
if [[ -d "$OUT/Contents/PlugIns/KERNPORTShareExtension.appex" ]]; then
  codesign --force --sign - \
    --entitlements "$ROOT_DIR/KERNPORTShareExtension/KERNPORTShareExtension.entitlements" \
    "$OUT/Contents/PlugIns/KERNPORTShareExtension.appex" >/dev/null
fi
codesign --force --sign - "$OUT" >/dev/null 2>&1 || \
  echo "  (codesign skipped — app will still run, may re-prompt for network)"

echo "✓ Built $OUT"
echo "  BUILD $BUILD_NUMBER · $GIT_COMMIT · $BUILD_DATE"
echo "  Run it:  open \"$OUT\""
