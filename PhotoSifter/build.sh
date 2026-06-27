#!/bin/bash
# Build script for PhotoSifter — produces a standalone .app bundle using swiftc.
# Works with Command Line Tools only (no Xcode.app required).
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT="$(pwd)"
SRC="$ROOT/PhotoSifter"
BUILD="$ROOT/Build"
APP="$BUILD/PhotoSifter.app"
BIN="$APP/Contents/MacOS/PhotoSifter"

SDK="$(xcrun --show-sdk-path)"
SWIFT_VER="$(swift -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 5.0)"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "==> Collecting Swift sources…"
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' -type f | sort)

echo "==> Found ${#SOURCES[@]} source files"

echo "==> Compiling (SDK: $SDK)…"
swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macos14 \
    -O \
    -parse-as-library \
    -module-name PhotoSifter \
    -framework QuickLookThumbnailing \
    -o "$BIN" \
    "${SOURCES[@]}"

echo "==> Copying Info.plist…"
cp "$SRC/PhotoSifter/Info.plist" "$APP/Contents/Info.plist"

echo "==> Copying Assets…"
cp -R "$SRC/PhotoSifter/Assets.xcassets" "$APP/Contents/Resources/" 2>/dev/null || true

# Sign ad-hoc so Gatekeeper allows launch.
echo "==> Ad-hoc signing…"
codesign --force --sign - "$APP" 2>/dev/null || echo "    (codesign skipped)"

echo ""
echo "✅ Build succeeded."
echo "   App: $APP"
echo "   Run: open \"$APP\""
