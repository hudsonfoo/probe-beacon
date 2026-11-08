#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/AppIcon.iconset"
SOURCE="$ROOT/assets/AppIcon-source.jpg"
ICNS="$ROOT/ProbeBeacon.app/Contents/Resources/AppIcon.icns"

if [[ ! -d "$ICONSET" ]]; then
  echo "Missing $ICONSET"
  exit 1
fi

if [[ -f "$SOURCE" ]]; then
  sips -s format png -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    d=$((size * 2))
    sips -z "$d" "$d" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
fi

mkdir -p "$(dirname "$ICNS")"
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Built $ICNS"
