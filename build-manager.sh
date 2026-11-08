#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BlueDOTManager.app"
BIN="$APP/Contents/MacOS/BlueDOTManager"
swiftc -parse-as-library -O -o "$BIN" "$ROOT/BlueDOTManager.swift" \
  -framework SwiftUI -framework Charts -framework AppKit \
  -framework CoreBluetooth -framework UserNotifications
/usr/bin/codesign --force --deep --sign - \
  --entitlements "$ROOT/BlueDOTManager.entitlements" \
  --options runtime \
  "$APP"
echo "Built and signed $APP"
