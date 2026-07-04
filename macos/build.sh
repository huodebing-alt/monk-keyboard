#!/bin/bash
# Build Comp.app (macOS input method), a .pkg installer, and a .zip.
# Requires: Xcode Command Line Tools, cmake (for the embedded LLM).
# Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
BUILD="$MACOS_DIR/build"
APP="$BUILD/Comp.app"
DIST="$ROOT/dist"
VERSION="1.1.0"

LLAMA_DIR="$ROOT/third_party/llama.cpp"
LLAMA_BUILD="$LLAMA_DIR/build"
MODEL_FILE="$MACOS_DIR/Models/smollm2-135m-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf"

echo "==> Ensuring llama.cpp (embedded LLM runtime)"
if [ ! -d "$LLAMA_DIR" ]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi
if [ ! -f "$LLAMA_BUILD/src/libllama.a" ]; then
  cmake -S "$LLAMA_DIR" -B "$LLAMA_BUILD" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release
  cmake --build "$LLAMA_BUILD" --config Release --target llama -j 8
fi

echo "==> Ensuring SmolLM2-135M model"
if [ ! -f "$MODEL_FILE" ]; then
  mkdir -p "$(dirname "$MODEL_FILE")"
  curl -L "$MODEL_URL" -o "$MODEL_FILE"
fi

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/dict" "$DIST"

LLAMA_LIBS=(
  "$LLAMA_BUILD/src/libllama.a"
  "$LLAMA_BUILD/ggml/src/libggml.a"
  "$LLAMA_BUILD/ggml/src/libggml-cpu.a"
  "$LLAMA_BUILD/ggml/src/libggml-base.a"
  "$LLAMA_BUILD/ggml/src/ggml-blas/libggml-blas.a"
)

echo "==> Compiling Swift sources"
swiftc -O -swift-version 5 \
  -import-objc-header "$MACOS_DIR/Sources/comp-bridging.h" \
  -I "$LLAMA_DIR/include" -I "$LLAMA_DIR/ggml/include" \
  -framework Cocoa -framework InputMethodKit -framework Accelerate \
  -o "$APP/Contents/MacOS/Comp" \
  "$MACOS_DIR/Sources/main.swift" \
  "$MACOS_DIR/Sources/ChordEngine.swift" \
  "$MACOS_DIR/Sources/LocalRanker.swift" \
  "$MACOS_DIR/Sources/CompInputController.swift" \
  "${LLAMA_LIBS[@]}" -lc++

echo "==> Assembling bundle"
cp "$MACOS_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
for lang in en es fr de it pt; do
  cp "$ROOT/dictionaries/$lang.tsv" "$APP/Contents/Resources/dict/"
done
cp "$MODEL_FILE" "$APP/Contents/Resources/model.gguf"
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
