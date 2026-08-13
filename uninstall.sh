#!/bin/zsh
# Removes the launchd agent, the installed script, the Desktop shortcut, and the Finder Quick
# Action. Your media folders (input/output/.processed) and settings are left alone, so nothing you
# recorded is deleted.

set -u

LABEL="com.shrinkit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"
BASE_DIR="${SHRINKIT_DIR:-$HOME/Movies/shrinkit}"

launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$BIN_DIR/shrinkit"

# remove the Desktop shortcut if it is a shortcut (never touch a real folder)
[[ -L "$HOME/Desktop/${BASE_DIR:t}" ]] && rm -f "$HOME/Desktop/${BASE_DIR:t}"

# Matched on the installed binary's own path, not a bare name, so a Quick Action of your own that
# happens to mention "shrinkit" is never swept up.
for action in "$HOME/Library/Services"/*.workflow(N); do
  grep -q "$BIN_DIR/shrinkit" "$action/Contents/document.wflow" 2> /dev/null && rm -rf "$action"
done
/System/Library/CoreServices/pbs -update 2> /dev/null || true

echo "Removed the agent, the script, the Desktop shortcut, and the Quick Action."
echo "Left in place (delete by hand if you want): $BASE_DIR"
