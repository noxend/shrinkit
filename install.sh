#!/bin/zsh
# Installs the demo-video optimizer: copies the script into place, creates the watch folders,
# installs the config, and registers a launchd agent that runs it whenever a recording is dropped
# into the input folder. Re-running it is safe: it updates the script and reloads the agent, and it
# never overwrites your settings.txt.
#
#   Optional: choose a different base folder before running:
#       DEMO_OPTIMIZER_DIR="$HOME/Movies/my-clips" ./install.sh

set -eu

REPO_DIR="${0:A:h}"
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DST="$BIN_DIR/optimize-demo-video.sh"
LABEL="com.demo-video-optimizer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Base folder: $BASE_DIR"

# macOS keeps Desktop, Documents and Downloads behind a privacy wall (TCC) that a background
# launchd job cannot write to. Refuse those so the agent does not silently fail.
case "$BASE_DIR" in
  "$HOME/Desktop"/*|"$HOME/Documents"/*|"$HOME/Downloads"/*|"$HOME/Desktop"|"$HOME/Documents"|"$HOME/Downloads")
    echo "!! $BASE_DIR is a macOS privacy-protected location; a background job cannot write there."
    echo "!! Pick a folder under ~/Movies (the default) or elsewhere outside Desktop/Documents/Downloads."
    exit 1 ;;
esac

# 1. ffmpeg
if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing ffmpeg via Homebrew (this can take a few minutes)..."
    brew install ffmpeg
  else
    echo "!! ffmpeg is required and Homebrew was not found."
    echo "!! Install Homebrew from https://brew.sh then run: brew install ffmpeg"
    exit 1
  fi
fi
FFMPEG_BIN="$(command -v ffmpeg)"
FFMPEG_DIR="${FFMPEG_BIN:h}"
echo "==> Using ffmpeg at $FFMPEG_BIN"

# 2. the script
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/optimize-demo-video.sh" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "==> Installed script: $SCRIPT_DST"

# 3. the folders
mkdir -p "$BASE_DIR/input" "$BASE_DIR/output" "$BASE_DIR/processed"

# 4. the config (never clobber an existing one)
if [[ -f "$BASE_DIR/settings.txt" ]]; then
  echo "==> Kept your existing settings.txt"
else
  cp "$REPO_DIR/settings.txt" "$BASE_DIR/settings.txt"
  echo "==> Installed default settings.txt"
fi

# 5. the launchd agent (paths must be absolute; that is why we generate it here)
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$SCRIPT_DST</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$BASE_DIR/input</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$FFMPEG_DIR:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>DEMO_OPTIMIZER_DIR</key>
        <string>$BASE_DIR</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$BASE_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$BASE_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
echo "==> Installed launchd agent: $PLIST"

# 6. (re)load it
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Drop a recording into:  $BASE_DIR/input"
echo "Pick up the optimized copy in: $BASE_DIR/output"
echo "Change behaviour any time by editing: $BASE_DIR/settings.txt"
