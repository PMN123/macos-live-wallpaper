#!/bin/bash
# Builds LiveWall.app — run on macOS with Xcode Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LiveWall"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"
EXT_NAME="LiveWallWallpaper"
EXT_DIR="$APP_DIR/Contents/Extensions/${EXT_NAME}.appex"

echo "▸ Compiling (release)…"
swift build -c release

echo "▸ Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
# The MIT notice for the code adapted from Phosphene travels with every copy.
cp THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"

# System wallpaper extension (macOS 26+): an ExtensionKit appex for the
# com.apple.wallpaper extension point, hosted by WallpaperAgent.
echo "▸ Assembling ${EXT_NAME}.appex…"
mkdir -p "$EXT_DIR/Contents/MacOS" "$EXT_DIR/Contents/Resources"
cp "$BUILD_DIR/$EXT_NAME" "$EXT_DIR/Contents/MacOS/$EXT_NAME"
cp Resources/LiveWallWallpaper-Info.plist "$EXT_DIR/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$EXT_DIR/Contents/Resources/"
# SwiftPM links every target at the package-wide macOS 13 deployment target and
# records "sdk 13.0". Stamp the extension with its real minimum (26.0, matching its
# LSMinimumSystemVersion) and the SDK it was compiled against.
xcrun vtool -set-build-version macos 26.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$EXT_DIR/Contents/MacOS/$EXT_NAME.tmp" "$EXT_DIR/Contents/MacOS/$EXT_NAME"
mv -f "$EXT_DIR/Contents/MacOS/$EXT_NAME.tmp" "$EXT_DIR/Contents/MacOS/$EXT_NAME"

echo "▸ Signing (ad-hoc)…"
# Inside-out, no --deep: the appex carries its own (sandbox) entitlements.
codesign --force --sign - --entitlements Resources/LiveWallWallpaper.entitlements "$EXT_DIR"
codesign --force --sign - "$APP_DIR"

echo "✓ Done: $APP_DIR"
echo "  Install:  cp -R \"$APP_DIR\" /Applications/"
echo "  Run:      open \"$APP_DIR\""
