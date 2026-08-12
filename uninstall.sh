#!/bin/zsh
# Removes the launchd agent, the installed script, the Desktop shortcut, and the Finder Quick
# Action. Your media folders (input/output/.processed) and settings are left alone, so nothing you
# recorded is deleted.

set -u

LABEL="com.shrinkit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"
BASE_DIR="${SHRINKIT_DIR:-$HOME/Movies/shrinkit}"

# the current name, plus the ones this tool went by before it was called shrinkit
for label in "$LABEL" com.demo-video-optimizer; do
  launchctl bootout "gui/$(id -u)/$label" 2> /dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -f "$BIN_DIR/shrinkit" "$BIN_DIR/demo-video-optimizer" "$BIN_DIR/optimize-demo-video.sh"

# remove the Desktop shortcuts if they are shortcuts (never touch a real folder)
for link in "$HOME/Desktop/${BASE_DIR:t}" "$HOME/Desktop/demo-recordings"; do
  [[ -L "$link" ]] && rm -f "$link"
done

# Matched on the installed binary's own path, not a bare name, so a Quick Action of your own that
# happens to mention "shrinkit" is never swept up.
for action in "$HOME/Library/Services"/*.workflow(N); do
  grep -qE "$BIN_DIR/(shrinkit|demo-video-optimizer|optimize-demo-video\.sh)" \
    "$action/Contents/document.wflow" 2> /dev/null && rm -rf "$action"
done
/System/Library/CoreServices/pbs -update 2> /dev/null || true

echo "Removed the agent, the script, the Desktop shortcut, and the Quick Action."
echo "Left in place (delete by hand if you want): $BASE_DIR"
