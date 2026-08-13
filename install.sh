#!/bin/zsh
# Installs shrinkit: copies the script into place, creates the watch folders, installs the config,
# and registers a launchd agent that runs it whenever a recording is dropped into the input folder.
# Re-running it is safe: it updates the script and reloads the agent, and it never overwrites your
# settings.
#
#   Optional: choose a different base folder before running:
#       SHRINKIT_DIR="$HOME/Movies/my-clips" ./install.sh

set -eu

REPO_DIR="${0:A:h}"
BASE_DIR="${SHRINKIT_DIR:-$HOME/Movies/shrinkit}"
BIN_DIR="$HOME/.local/bin"
# Installed without a .sh extension so it reads as "shrinkit" (not "zsh") in the
# System Settings > Login Items background list.
SCRIPT_DST="$BIN_DIR/shrinkit"
LABEL="com.shrinkit"
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
cp "$REPO_DIR/shrinkit.sh" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "==> Installed script: $SCRIPT_DST"

# 3. the folders (processed/ and logs/ are hidden so the folder shows only settings + input + output)
mkdir -p "$BASE_DIR/input" "$BASE_DIR/output" "$BASE_DIR/.processed" "$BASE_DIR/.logs"

# A first install gets all three example presets; after that the folder is yours, and an empty
# one is a deliberate choice rather than something to repopulate.
mkdir -p "$BASE_DIR/presets"
if [[ -z "$(ls -A "$BASE_DIR/presets")" && ! -f "$BASE_DIR/settings.conf" ]]; then
  cp "$REPO_DIR/presets/2x.conf" "$REPO_DIR/presets/sharp.conf" "$REPO_DIR/presets/tiny.conf" "$BASE_DIR/presets/"
  echo "==> Installed the example presets: 2x, sharp, tiny"
fi
# "default" set nothing and only existed to hold a place in the menu; "2x" pins the speed it
# always meant. Only retired if it is still setting-free, so an edited one is left alone.
if [[ -f "$BASE_DIR/presets/default.conf" ]] \
  && ! grep -qE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$BASE_DIR/presets/default.conf"; then
  rm -f "$BASE_DIR/presets/default.conf"
  [[ -f "$BASE_DIR/presets/2x.conf" ]] || cp "$REPO_DIR/presets/2x.conf" "$BASE_DIR/presets/"
  echo "==> Replaced the empty 'default' preset with '2x'"
fi
# "chat" is renamed "tiny": a name that says what the file becomes rather than where it is going.
# Only touches an install that still has the old file, so a folder that was deliberately cleared
# out stays that way.
if [[ -f "$BASE_DIR/presets/chat.conf" && ! -f "$BASE_DIR/presets/tiny.conf" ]]; then
  mv "$BASE_DIR/presets/chat.conf" "$BASE_DIR/presets/tiny.conf"
  echo "==> Renamed the 'chat' preset to 'tiny'"
fi
# "hq" is renamed "sharp": says what it does without needing the abbreviation spelled out.
if [[ -f "$BASE_DIR/presets/hq.conf" && ! -f "$BASE_DIR/presets/sharp.conf" ]]; then
  mv "$BASE_DIR/presets/hq.conf" "$BASE_DIR/presets/sharp.conf"
  echo "==> Renamed the 'hq' preset to 'sharp'"
fi
# New since 2x/tiny existed; an install that predates it just does not have the file yet.
if [[ ! -f "$BASE_DIR/presets/sharp.conf" ]]; then
  cp "$REPO_DIR/presets/sharp.conf" "$BASE_DIR/presets/"
  echo "==> Added the new 'sharp' preset"
fi

# 4. the config; an existing settings.conf is never touched.
CONFIG="$BASE_DIR/settings.conf"
if [[ -f "$CONFIG" ]]; then
  echo "==> Kept your existing settings"
else
  cp "$REPO_DIR/settings.conf" "$CONFIG"
  echo "==> Installed default settings.conf"
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
    <!-- Direct shebang execution, so Login Items shows "shrinkit" rather than "zsh". -->
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
        <key>SHRINKIT_DIR</key>
        <string>$BASE_DIR</string>
        <key>SHRINKIT_REPO</key>
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

# 6. Desktop shortcut to the working folder, which itself stays outside TCC-protected locations.
if [[ "$BASE_DIR" != "$HOME/Desktop/"* ]]; then
  LINK="$HOME/Desktop/${BASE_DIR:t}"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "!! $LINK already exists as a real folder; skipping the Desktop shortcut."
  else
    ln -sfn "$BASE_DIR" "$LINK"
    echo "==> Desktop shortcut: $LINK -> $BASE_DIR"
  fi
fi

# 7. one right-click entry per preset; rebuilt fresh each run so a deleted preset leaves nothing.
SERVICES_DIR="$HOME/Library/Services"
mkdir -p "$SERVICES_DIR"
for STALE in "$SERVICES_DIR"/shrinkit:*.workflow(N); do rm -rf "$STALE"; done

INSTALLED=()
for PRESET_PATH in "$BASE_DIR/presets"/*.conf(N.); do
  PRESET_NAME="${PRESET_PATH:t:r}"
  SHRINKIT_DIR="$BASE_DIR" SHRINKIT_REPO="$REPO_DIR" \
    "$SCRIPT_DST" preset install "$PRESET_NAME" > /dev/null
  INSTALLED+=("$PRESET_NAME")
done
SHRINKIT_DIR="$BASE_DIR" SHRINKIT_REPO="$REPO_DIR" "$SCRIPT_DST" mark-cuts --install > /dev/null
echo "==> Finder entries, one per preset, plus 'shrinkit: mark cuts': ${INSTALLED[*]}"

# 8. (re)load it
launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Open the 'shrinkit' shortcut on your Desktop:"
echo "  - drop recordings into  input/"
echo "  - pick up results from  output/"
echo "  - change behaviour by editing  settings.conf"
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
