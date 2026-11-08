#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BlueDOTManager.app"
BIN="$APP/Contents/MacOS/BlueDOTManager"
if [[ -d "$ROOT/AppIcon.iconset" ]]; then
  "$ROOT/scripts/build-app-icon.sh"
fi
swiftc -parse-as-library -O -o "$BIN" "$ROOT/ThermometerProfiles.swift" "$ROOT/BlueDOTManager.swift" \
  -framework SwiftUI -framework Charts -framework AppKit \
  -framework CoreBluetooth -framework UserNotifications
RES="$APP/Contents/Resources/ingest-server"
rm -rf "$RES"
mkdir -p "$RES"
cp "$ROOT/ingest-server/server.js" "$ROOT/ingest-server/package.json" "$RES/"
/usr/bin/codesign --force --deep --sign - \
  --entitlements "$ROOT/BlueDOTManager.entitlements" \
  --options runtime \
  "$APP"
echo "Built and signed $APP"
