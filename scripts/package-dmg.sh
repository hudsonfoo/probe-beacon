#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ProbeBeacon.app/Contents/Info.plist")
STAGING="$ROOT/build/dmg-root"
DMG_NAME="ProbeBeacon-${VERSION}.dmg"

cd "$ROOT"
./build-manager.sh

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$ROOT/ProbeBeacon.app" "$STAGING/ProbeBeacon.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$ROOT/build/$DMG_NAME"
mkdir -p "$ROOT/build"
hdiutil create \
  -volname "ProbeBeacon ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$ROOT/build/$DMG_NAME"

echo "Created $ROOT/build/$DMG_NAME"
