#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP="Klang.app"
BIN_NAME="Klang"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Signing (hardened runtime + entitlements, ad-hoc)..."
# Ad-hoc signature (-) is fine for personal/local use. Replace "-" with a
# Developer ID identity to distribute to other machines.
codesign --force --options runtime \
    --entitlements Resources/Klang.entitlements \
    --sign - \
    "$APP"

echo "Done: $APP"
echo "Install:  cp -R $APP /Applications/ && open /Applications/$APP"
