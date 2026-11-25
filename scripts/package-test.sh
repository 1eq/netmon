#!/usr/bin/env bash
# Packages a test build for someone else to try, in ./dist:
#   NetMon-<version>.zip         NetMon.app + install.sh + TESTING.md (not notarized)
#   netmon-source-<version>.zip  the source, to build with scripts/build-app.sh
# Usage: VERSION=0.1.0 scripts/package-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.1.0}"
DIST="dist"
STAGE="$DIST/NetMon-$VERSION"

swift test
./scripts/build-app.sh

rm -rf "$STAGE" "$DIST/NetMon-$VERSION.zip" "$DIST/netmon-source-$VERSION.zip"
mkdir -p "$STAGE"
cp -R build/NetMon.app "$STAGE/"
cp scripts/install.sh docs/TESTING.md "$STAGE/"
chmod +x "$STAGE/install.sh"
# ditto keeps the bundle's code signature and symlinks intact.
(cd "$DIST" && ditto -c -k --keepParent "NetMon-$VERSION" "NetMon-$VERSION.zip")
rm -rf "$STAGE"

zip -qr "$DIST/netmon-source-$VERSION.zip" Package.swift README.md LICENSE .gitignore Sources Tests scripts docs \
  -x '*.DS_Store'

echo
echo "Test build $VERSION:"
ls -lh "$DIST"/*"$VERSION"*.zip
