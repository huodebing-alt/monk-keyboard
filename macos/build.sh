#!/bin/bash
# Build Comp.app (macOS input method), a .pkg installer, and a .zip.
# Requires: Xcode Command Line Tools. Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
BUILD="$MACOS_DIR/build"
APP="$BUILD/Comp.app"
DIST="$ROOT/dist"
VERSION="1.0.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/dict" "$DIST"

echo "==> Compiling Swift sources"
swiftc -O -swift-version 5 \
  -framework Cocoa -framework InputMethodKit \
  -o "$APP/Contents/MacOS/Comp" \
  "$MACOS_DIR/Sources/main.swift" \
  "$MACOS_DIR/Sources/ChordEngine.swift" \
  "$MACOS_DIR/Sources/LLMRanker.swift" \
  "$MACOS_DIR/Sources/CompInputController.swift"

echo "==> Assembling bundle"
cp "$MACOS_DIR/Info.plist" "$APP/Contents/Info.plist"
for lang in en es fr de it pt; do
  cp "$ROOT/dictionaries/$lang.tsv" "$APP/Contents/Resources/dict/"
done
if [ -f "$MACOS_DIR/Resources/comp.tiff" ]; then
  cp "$MACOS_DIR/Resources/comp.tiff" "$APP/Contents/Resources/"
fi

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Building zip (per-user install, no admin needed)"
cp "$MACOS_DIR/install.sh" "$BUILD/install.sh"
chmod +x "$BUILD/install.sh"
(cd "$BUILD" && zip -qry "$DIST/Comp-$VERSION-macos.zip" Comp.app install.sh)

echo "==> Building pkg (system-wide install)"
PKGROOT="$BUILD/pkgroot"
mkdir -p "$PKGROOT/Library/Input Methods"
cp -R "$APP" "$PKGROOT/Library/Input Methods/"
pkgbuild --root "$PKGROOT" \
  --identifier com.compkeyboard.inputmethod.Comp \
  --version "$VERSION" \
  --install-location / \
  "$DIST/Comp-$VERSION-macos.pkg" >/dev/null

echo "==> Done:"
ls -lh "$DIST"
