#!/bin/bash
# Package the built PhotoSifter.app as "Deleter.app" with the Deleter icon,
# then build a pretty drag-to-Applications DMG into release/v1.0.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/Build"
SRC_APP="$BUILD/PhotoSifter.app"
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

echo "==> Staging Deleter.app (renamed from PhotoSifter.app)…"
cp -R "$SRC_APP" "$DMG_APP"

# Rename the executable + fix Info.plist to present as "Deleter".
BIN_OLD="$DMG_APP/Contents/MacOS/PhotoSifter"
BIN_NEW="$DMG_APP/Contents/MacOS/Deleter"
if [ -f "$BIN_OLD" ]; then
    mv "$BIN_OLD" "$BIN_NEW"
fi
PLIST="$DMG_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Deleter" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Deleter" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Deleter" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.deleter.app" "$PLIST"
# Keep version strings.
# Point the bundle at our custom icon.
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
