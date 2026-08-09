#!/bin/zsh
# Installs the shrinkit: copies the script into place, creates the watch folders,
# installs the config, and registers a launchd agent that runs it whenever a recording is dropped
# into the input folder. Re-running it is safe: it updates the script and reloads the agent, and it
# never overwrites your settings.
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

# The tool used to be called demo-video-optimizer. Take the old install apart before building the
# new one, or the machine ends up with two agents watching two folders.
OLD_LABEL="com.demo-video-optimizer"
OLD_BASE="$HOME/Movies/demo-recordings"
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2> /dev/null || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
rm -f "$BIN_DIR/demo-video-optimizer" "$BIN_DIR/optimize-demo-video.sh"
[[ -L "$HOME/Desktop/demo-recordings" ]] && rm -f "$HOME/Desktop/demo-recordings"
# Menu entries from an older install point at a command that has just been removed, so they would
# sit there doing nothing. Matched on the command inside, not the name, to leave your own alone.
setopt extended_glob
for action in "$HOME/Library/Services"/*.workflow(N); do
  grep -q 'demo-video-optimizer' "$action/Contents/document.wflow" 2> /dev/null && rm -rf "$action"
done
# Recordings and settings move across with it, but only into a folder that is not already there,
# and only when you have not named one yourself.
if [[ -z "${SHRINKIT_DIR+set}" && -d "$OLD_BASE" && ! -d "$BASE_DIR" ]]; then
  mv "$OLD_BASE" "$BASE_DIR"
  echo "==> Moved $OLD_BASE to $BASE_DIR"
fi

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

# The presets are what the right-click menu is built from, so default.conf is put back whenever it
# is missing: without it there is no menu entry for plain settings. chat.conf is only an example,
# so it arrives once and is never restored if you delete it. Neither is ever overwritten.
mkdir -p "$BASE_DIR/presets"
[[ -f "$BASE_DIR/presets/default.conf" ]] || cp "$REPO_DIR/presets/default.conf" "$BASE_DIR/presets/"
if [[ -z "$(ls -A "$BASE_DIR/presets" | grep -v '^default.conf$')" ]]; then
  cp "$REPO_DIR/presets/chat.conf" "$BASE_DIR/presets/chat.conf"
  echo "==> Installed the example preset: presets/chat.conf"
fi

# 4. the config. Settings used to be JSON with comments; the format is now plain "key = value",
#    so an older install gets converted once. The old file is left behind as a backup, and an
#    existing settings.conf is never touched.
CONFIG="$BASE_DIR/settings.conf"
if [[ -f "$CONFIG" ]]; then
  echo "==> Kept your existing settings"
elif [[ -f "$BASE_DIR/settings.jsonc" ]]; then
  # Into a temp file first: a config that failed to convert must not land as an empty one, which
  # would look like a valid file full of nothing and quietly put every setting back to default.
  CONVERTED="$(mktemp)"
  if osascript -l JavaScript - "$BASE_DIR/settings.jsonc" > "$CONVERTED" << 'JXA' && [[ -s "$CONVERTED" ]]; then
function run(argv) {
  const raw = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], 4, null)) || '';
  const json = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[\s,{])\/\/.*$/gm, '$1');
  const settings = JSON.parse(json);
  return Object.keys(settings).map(function (k) { return k + ' = ' + settings[k] }).join('\n');
}
JXA
    mv "$CONVERTED" "$CONFIG"
    mv "$BASE_DIR/settings.jsonc" "$BASE_DIR/settings.jsonc.bak"
    echo "==> Converted settings.jsonc to settings.conf (old file kept as settings.jsonc.bak)"
  else
    rm -f "$CONVERTED"
    cp "$REPO_DIR/settings.conf" "$CONFIG"
    echo "!! Could not read settings.jsonc, so it was left alone and a default settings.conf"
    echo "!! was installed. Copy your values across by hand, then delete settings.jsonc."
  fi
elif [[ -f "$BASE_DIR/settings.txt" ]]; then
  mv "$BASE_DIR/settings.txt" "$CONFIG"
  echo "==> Renamed settings.txt to settings.conf"
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
    <!-- Run the script directly (it has a #!/bin/zsh shebang) so the background item shows as
         "shrinkit" instead of "zsh". -->
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

# 7. one right-click entry per preset, so the menu is the list of presets and nothing has to be
#    picked out of a dialog. The menu is rebuilt from presets/ every time, which is what keeps a
#    preset you deleted from leaving an entry behind. Skip the lot with QUICK_ACTION=0.
if [[ "${QUICK_ACTION:-1}" == 1 ]]; then
  SERVICES_DIR="$HOME/Library/Services"
  mkdir -p "$SERVICES_DIR"
  # Entries these replaced, named one by one so nothing else in the menu is touched.
  for RETIRED in "Shrink Video" "Shrink Video with" "shrinkit" "shrinkit presets"; do
    rm -rf "$SERVICES_DIR/$RETIRED.workflow"
  done
  for STALE in "$SERVICES_DIR"/shrinkit:*.workflow(N); do rm -rf "$STALE"; done

  INSTALLED=()
  for PRESET_PATH in "$BASE_DIR/presets"/*.conf(N.); do
    PRESET_NAME="${PRESET_PATH:t:r}"
    SHRINKIT_DIR="$BASE_DIR" SHRINKIT_REPO="$REPO_DIR" \
      "$SCRIPT_DST" preset install "$PRESET_NAME" > /dev/null
    INSTALLED+=("$PRESET_NAME")
  done
  echo "==> Finder entries, one per preset: ${INSTALLED[*]}"
fi

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
