#!/bin/bash
# Package the built Deleter.app (with the Deleter icon) into a pretty
# drag-to-Applications DMG into release/v1.0.
set -euo pipefail

cd "$(dirname "$0")"

ROOT="$(pwd)"
BUILD="$ROOT/Build"
SRC_APP="$BUILD/Deleter.app"
RELEASE="$ROOT/release/v1.0"
ICONSET_ICNS="$RELEASE/Deleter.icns"

if [ ! -d "$SRC_APP" ]; then
    echo "❌ $SRC_APP not found. Run build.sh first." >&2
    exit 1
fi
if [ ! -f "$ICONSET_ICNS" ]; then
    echo "❌ $ICONSET_ICNS not found. Run make_icon.py first." >&2
    exit 1
fi

STAGE="$BUILD/stage"
DMG_APP="$STAGE/Deleter.app"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> Staging Deleter.app…"
cp -R "$SRC_APP" "$DMG_APP"

# Point the bundle at our custom icon.
PLIST="$DMG_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Deleter" "$PLIST"

echo "==> Installing icon into app bundle…"
cp "$ICONSET_ICNS" "$DMG_APP/Contents/Resources/Deleter.icns"

echo "==> Re-signing (ad-hoc)…"
codesign --force --sign - --deep "$DMG_APP" 2>/dev/null || echo "    (codesign skipped)"

echo "==> Building DMG…"
DMG="$RELEASE/Deleter.dmg"
rm -f "$DMG"
# Symlink Applications so users can drag the app into it.
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Deleter" -srcfolder "$STAGE" \
    -ov -format UDBZ "$DMG"

echo "==> Cleaning up stage…"
rm -rf "$STAGE"

echo ""
echo "✅ DMG built."
echo "   $DMG"
echo "   Mount: open \"$DMG\""
