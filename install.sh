#!/bin/zsh
# Installs the demo-video optimizer: copies the script into place, creates the watch folders,
# installs the config, and registers a launchd agent that runs it whenever a recording is dropped
# into the input folder. Re-running it is safe: it updates the script and reloads the agent, and it
# never overwrites your settings.
#
#   Optional: choose a different base folder before running:
#       DEMO_OPTIMIZER_DIR="$HOME/Movies/my-clips" ./install.sh

set -eu

REPO_DIR="${0:A:h}"
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"
BIN_DIR="$HOME/.local/bin"
# Installed without a .sh extension so it reads as "demo-video-optimizer" (not "zsh") in the
# System Settings > Login Items background list.
SCRIPT_DST="$BIN_DIR/demo-video-optimizer"
LABEL="com.demo-video-optimizer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Base folder: $BASE_DIR"

# macOS keeps Desktop, Documents and Downloads behind a privacy wall (TCC). A background launchd
# job is denied there (silently, with no prompt) until it is granted Full Disk Access by hand.
NEEDS_FDA=0
case "$BASE_DIR" in
  "$HOME/Desktop"/* | "$HOME/Documents"/* | "$HOME/Downloads"/* | "$HOME/Desktop" | "$HOME/Documents" | "$HOME/Downloads")
    NEEDS_FDA=1
    ;;
esac

# 1. ffmpeg
if ! command -v ffmpeg > /dev/null 2>&1; then
  if command -v brew > /dev/null 2>&1; then
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
rm -f "$BIN_DIR/optimize-demo-video.sh" # drop the name used by older installs
cp "$REPO_DIR/optimize-demo-video.sh" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "==> Installed script: $SCRIPT_DST"

# 3. the folders (processed/ and logs/ are hidden so the folder shows only settings + input + output)
mkdir -p "$BASE_DIR/input" "$BASE_DIR/output" "$BASE_DIR/.processed" "$BASE_DIR/.logs"

# 4. the config (never clobber an existing one; keep a legacy settings.txt working too)
if [[ -f "$BASE_DIR/settings.jsonc" || -f "$BASE_DIR/settings.txt" ]]; then
  echo "==> Kept your existing settings"
else
  cp "$REPO_DIR/settings.jsonc" "$BASE_DIR/settings.jsonc"
  echo "==> Installed default settings.jsonc"
fi

# 5. the launchd agent (paths must be absolute; that is why we generate it here)
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- Run the script directly (it has a #!/bin/zsh shebang) so the background item shows as
         "demo-video-optimizer" instead of "zsh". -->
    <key>ProgramArguments</key>
    <array>
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
        <key>DEMO_OPTIMIZER_REPO</key>
        <string>$REPO_DIR</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$BASE_DIR/.logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$BASE_DIR/.logs/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
echo "==> Installed launchd agent: $PLIST"

# 6. a shortcut on the Desktop pointing at the working folder, so you reach input/ and output/
#    from the Desktop while the real folder stays in a non-protected location (no permissions
#    needed). Skipped when the base is already on the Desktop, or with DESKTOP_SHORTCUT=0.
if [[ "${DESKTOP_SHORTCUT:-1}" == 1 && "$BASE_DIR" != "$HOME/Desktop/"* ]]; then
  LINK="$HOME/Desktop/${BASE_DIR:t}"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "!! $LINK already exists as a real folder; skipping the Desktop shortcut."
  else
    ln -sfn "$BASE_DIR" "$LINK"
    echo "==> Desktop shortcut: $LINK -> $BASE_DIR"
  fi
fi

# 7. a Finder Quick Action, so you can right-click any video and pick "Optimize Video" without
#    dropping it into the watch folder. It writes the result next to the source. Skip with
#    QUICK_ACTION=0.
if [[ "${QUICK_ACTION:-1}" == 1 ]]; then
  SERVICES_DIR="$HOME/Library/Services"
  QA_SRC="$REPO_DIR/quick-action/Optimize Video.workflow"
  QA_DST="$SERVICES_DIR/Optimize Video.workflow"
  mkdir -p "$SERVICES_DIR"
  rm -rf "$QA_DST"
  cp -R "$QA_SRC" "$QA_DST"
  # Fill in the command with the real paths. plutil writes the value verbatim, so there is no
  # shell-quoting to fight with. "$@" forwards the file(s) Finder passes as arguments.
  QA_CMD="DEMO_OPTIMIZER_DIR=\"$BASE_DIR\" \"$SCRIPT_DST\" \"\$@\""
  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string "$QA_CMD" \
    "$QA_DST/Contents/document.wflow"
  # Register it so it shows up in the right-click menu without a logout.
  /System/Library/CoreServices/pbs -update 2> /dev/null || true
  echo "==> Installed Finder Quick Action: right-click a video > Quick Actions > Optimize Video"
fi

# 8. (re)load it
launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Open the 'demo-recordings' shortcut on your Desktop:"
echo "  - drop recordings into  input/"
echo "  - pick up results from  output/"
echo "  - change behaviour by editing  settings.jsonc"
echo "(The real folder is $BASE_DIR; the Desktop item is a shortcut to it.)"

if [[ "$NEEDS_FDA" == 1 ]]; then
  cat << FDA

------------------------------------------------------------------------
ONE-TIME STEP: $BASE_DIR is in a macOS privacy-protected location.
A background job cannot write there until you grant it Full Disk Access:

  1. Open  System Settings > Privacy & Security > Full Disk Access
  2. Click the + button (authenticate if asked)
  3. Press Cmd+Shift+G and paste:  $SCRIPT_DST
  4. Add it, and make sure its switch is ON
  5. Run this to restart the agent:
       launchctl bootout gui/\$(id -u)/$LABEL 2>/dev/null; launchctl bootstrap gui/\$(id -u) "$PLIST"

Until then, recordings dropped in input/ will not be processed.
------------------------------------------------------------------------
FDA
fi
