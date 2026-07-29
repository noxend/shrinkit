#!/bin/zsh
# Removes the launchd agent and the installed script. Your media folders (input/output/processed)
# and settings.txt are left alone, so nothing you recorded is deleted.

set -u

LABEL="com.demo-video-optimizer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# remove the current name and the one older installs used
rm -f "$PLIST" "$BIN_DIR/demo-video-optimizer" "$BIN_DIR/optimize-demo-video.sh"

echo "Removed the agent and the script."
echo "Left in place (delete by hand if you want): $BASE_DIR"
