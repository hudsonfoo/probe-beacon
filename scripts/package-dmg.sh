#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/BlueDOTManager.app/Contents/Info.plist")
STAGING="$ROOT/build/dmg-root"
DMG_NAME="BlueDOT-Manager-${VERSION}.dmg"

cd "$ROOT"
./build-manager.sh

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$ROOT/BlueDOTManager.app" "$STAGING/BlueDOT Manager.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$ROOT/build/$DMG_NAME"
mkdir -p "$ROOT/build"
hdiutil create \
  -volname "BlueDOT Manager ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$ROOT/build/$DMG_NAME"

echo "Created $ROOT/build/$DMG_NAME"
