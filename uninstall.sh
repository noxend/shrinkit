#!/bin/zsh
# Removes the launchd agent and the installed script. Your media folders (input/output/processed)
# and settings.txt are left alone, so nothing you recorded is deleted.

set -u

LABEL="com.demo-video-optimizer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DST="$HOME/.local/bin/optimize-demo-video.sh"
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$SCRIPT_DST"

echo "Removed the agent and the script."
echo "Left in place (delete by hand if you want): $BASE_DIR"
