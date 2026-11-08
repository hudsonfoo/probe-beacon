#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BlueDOTReceiver.app"
BIN="$APP/Contents/MacOS/BlueDOTReceiver"
mkdir -p "$(dirname "$BIN")"
swiftc -O -o "$BIN" "$ROOT/BlueDOTReceiver.swift" -framework Cocoa -framework CoreBluetooth
/usr/bin/codesign --force --deep --sign - --options runtime "$APP"
echo "Built and signed $APP"
