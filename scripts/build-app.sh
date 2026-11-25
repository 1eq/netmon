#!/usr/bin/env bash
# Builds NetMon.app (release) into ./build, and with --install copies it to /Applications
# (falling back to ~/Applications) and launches it.
#   VERSION        version string for Info.plist (default 0.0.0-dev)
#   SIGN_IDENTITY  codesigning identity, e.g. "Developer ID Application: …" (default "-", ad-hoc)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/NetMon.app"
VERSION="${VERSION:-0.0.0-dev}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/NetMon"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetMon"
# Rendered by the in-app Guide screen.
cp docs/HOW-IT-WORKS.md "$APP/Contents/Resources/"
cp Resources/NetMon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.babyscripts.netmon</string>
    <key>CFBundleName</key><string>NetMon</string>
    <key>CFBundleDisplayName</key><string>NetMon</string>
    <key>CFBundleExecutable</key><string>NetMon</string>
    <key>CFBundleIconFile</key><string>NetMon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- macOS reveals Wi-Fi network names, access point addresses and beacon data only to apps with Location permission. -->
    <key>NSLocationUsageDescription</key><string>NetMon uses Location Services only so macOS will show Wi-Fi network names and access point details for the Wi-Fi analyzer. Your location is never stored or sent anywhere.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>NetMon uses Location Services only so macOS will show Wi-Fi network names and access point details for the Wi-Fi analyzer. Your location is never stored or sent anywhere.</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  # Notarization needs the hardened runtime and a secure timestamp. Under the hardened runtime,
  # Location Services also needs its entitlement.
  codesign --force --options runtime --timestamp --entitlements scripts/NetMon.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications"
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x NetMon 2>/dev/null || true
  rm -rf "$DEST/NetMon.app"
  cp -R "$APP" "$DEST/"
  echo "Installed to $DEST/NetMon.app"

  # CLI: the same binary, run as `netmon <command>`.
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DEST/NetMon.app/Contents/MacOS/NetMon" "$HOME/.local/bin/netmon"
  echo "Linked $HOME/.local/bin/netmon"

  open "$DEST/NetMon.app"
fi
