#!/usr/bin/env bash
# Prints the Homebrew cask for a release. The release workflow writes it to the tap
# (1eq/homebrew-tap, Casks/netmon.rb).
# Usage: scripts/make-cask.sh <version> <sha256 of NetMon-<version>.zip>
set -euo pipefail

VERSION="${1:?version}"
SHA="${2:?sha256}"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "not a sha256: $SHA" >&2; exit 1; }

cat <<CASK
cask "netmon" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/1eq/netmon/releases/download/v#{version}/NetMon-#{version}.zip"
  name "NetMon"
  desc "Menu bar network monitor with mtr-style hop diagnosis and Wi-Fi analysis"
  homepage "https://github.com/1eq/netmon"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "NetMon.app"
  binary "#{appdir}/NetMon.app/Contents/MacOS/NetMon", target: "netmon"

  uninstall quit: "com.babyscripts.netmon"

  zap trash: [
    "~/Library/Application Support/NetMon",
    "~/Library/Preferences/com.babyscripts.netmon.plist",
  ]
end
CASK
