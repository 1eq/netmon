#!/usr/bin/env bash
# Installs a NetMon test build from the folder this script is in: copies NetMon.app to
# /Applications (or ~/Applications), clears the download quarantine because test builds
# aren't notarized, links the `netmon` CLI into ~/.local/bin, and starts the app.
set -euo pipefail

cd "$(dirname "$0")"
[[ -d NetMon.app ]] || { echo "NetMon.app not found next to this script" >&2; exit 1; }

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x NetMon 2>/dev/null || true
rm -rf "$DEST/NetMon.app"
cp -R NetMon.app "$DEST/"
xattr -dr com.apple.quarantine "$DEST/NetMon.app" 2>/dev/null || true
echo "Installed $DEST/NetMon.app"

mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/NetMon.app/Contents/MacOS/NetMon" "$HOME/.local/bin/netmon"
echo "Linked $HOME/.local/bin/netmon"

open "$DEST/NetMon.app"
echo "NetMon is running: look for the dot in the menu bar."

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo
     echo "Note: ~/.local/bin isn't on your PATH. Add this to ~/.zshrc to use \`netmon\`:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo
echo "To use it from Claude Code, run once:"
echo "  claude mcp add --scope user netmon -- $DEST/NetMon.app/Contents/MacOS/NetMon --mcp"
