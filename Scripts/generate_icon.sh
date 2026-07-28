#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift Scripts/generate_icon.swift /tmp/downmix-icon-1024.png
rm -rf /tmp/Downmix.iconset
mkdir -p /tmp/Downmix.iconset

for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  set -- $spec
  sips -z "$1" "$1" /tmp/downmix-icon-1024.png --out "/tmp/Downmix.iconset/$2" >/dev/null
 done

swift Scripts/pack_icns.swift /tmp/Downmix.iconset Icon.icns
echo "Wrote $ROOT/Icon.icns"
