#!/usr/bin/env bash
# Regenerate the macOS icon from the 1024px artwork used in the README.
set -euo pipefail
cd "$(dirname "$0")/.."

ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/NetMon.iconset"
mkdir -p "$ICONSET" Resources

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" docs/assets/netmon-icon.png \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" docs/assets/netmon-icon.png \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/NetMon.icns
echo "Built Resources/NetMon.icns"
