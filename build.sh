#!/bin/bash
# Builds LiveWall.app — run on macOS with Xcode Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LiveWall"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

echo "▸ Compiling (release)…"
swift build -c release

echo "▸ Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "✓ Done: $APP_DIR"
echo "  Install:  cp -R \"$APP_DIR\" /Applications/"
echo "  Run:      open \"$APP_DIR\""
