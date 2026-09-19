#!/bin/bash
set -euo pipefail

echo "Building Photozen..."
swift build --cache-path ./.build/cache --manifest-cache local

echo "Packaging .app bundle..."
APP_DIR="build/Photozen.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/out/Products/Debug/Photozen "$APP_DIR/Contents/MacOS/Photozen"

if [ ! -f "$APP_DIR/Contents/Info.plist" ]; then
    echo "Warning: Info.plist missing — run from project root." >&2
    exit 1
fi

codesign --force --sign - "$APP_DIR" 2>/dev/null || true

echo "✅ Done: $PWD/$APP_DIR"
