#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- setup and teardown

LABEL="com.shrinkit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Reached through a variable so a test can watch what setup asks launchd for. The real one needs an
# Aqua session CI does not have, and running it for real during a test on a developer's machine
# would boot out the agent they are actually using.
LAUNCHCTL="${SHRINKIT_LAUNCHCTL:-launchctl}"

needs_full_disk_access() {
  guarded_path "$BASE_DIR"
}

# processed/ and logs/ are hidden, so the working folder shows only settings, presets, input and
# output.
setup_folders() {
  mkdir -p "$IN_DIR" "$OUT_DIR" "$DONE_DIR" "$LOG_DIR" "$PRESET_DIR" "$HOME/Library/LaunchAgents"
}

# A first install gets the three example presets; after that the folder is yours, and an empty one
# is a deliberate choice rather than something to repopulate. Every rename below is keyed on which
# files exist, so running setup again changes nothing it has already done.
setup_presets() {
  if [[ -z "$(ls -A "$PRESET_DIR")" && ! -f "$CONFIG" ]]; then
    cp "$REPO_DIR/presets/2x.conf" "$REPO_DIR/presets/sharp.conf" "$REPO_DIR/presets/tiny.conf" "$PRESET_DIR/"
    print -r -- "==> Installed the example presets: 2x, sharp, tiny"
  fi
  # "default" set nothing and only existed to hold a place in the menu; "2x" pins the speed it
  # always meant. Only retired while it is still setting-free, so an edited one is left alone.
  if [[ -f "$PRESET_DIR/default.conf" ]] \
    && ! grep -qE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$PRESET_DIR/default.conf"; then
    rm -f "$PRESET_DIR/default.conf"
    [[ -f "$PRESET_DIR/2x.conf" ]] || cp "$REPO_DIR/presets/2x.conf" "$PRESET_DIR/"
    print -r -- "==> Replaced the empty 'default' preset with '2x'"
  fi
  # "chat" is renamed "tiny": a name that says what the file becomes rather than where it is going.
  if [[ -f "$PRESET_DIR/chat.conf" && ! -f "$PRESET_DIR/tiny.conf" ]]; then
    mv "$PRESET_DIR/chat.conf" "$PRESET_DIR/tiny.conf"
    print -r -- "==> Renamed the 'chat' preset to 'tiny'"
  fi
  # "hq" is renamed "sharp": says what it does without needing the abbreviation spelled out.
  if [[ -f "$PRESET_DIR/hq.conf" && ! -f "$PRESET_DIR/sharp.conf" ]]; then
    mv "$PRESET_DIR/hq.conf" "$PRESET_DIR/sharp.conf"
    print -r -- "==> Renamed the 'hq' preset to 'sharp'"
  fi
  # New since 2x and tiny existed; an install that predates it just does not have the file yet.
  if [[ ! -f "$PRESET_DIR/sharp.conf" ]]; then
    cp "$REPO_DIR/presets/sharp.conf" "$PRESET_DIR/"
    print -r -- "==> Added the new 'sharp' preset"
  fi
}

setup_config() {
  if [[ -f "$CONFIG" ]]; then
    print -r -- "==> Kept your existing settings"
  else
    cp "$REPO_DIR/settings.conf" "$CONFIG"
    print -r -- "==> Installed default settings.conf"
  fi
}

# The agent has to name absolute paths, which is why the plist is written here rather than shipped.
# It carries no SHRINKIT_REPO: the script finds its own data directory now, so an agent registered
# before a move or an upgrade cannot be left pointing at a folder that is gone.
setup_plist() {
  local program="$1" ffmpeg_dir="${FFMPEG:h}"
  [[ -x "$FFMPEG" ]] || ffmpeg_dir="/opt/homebrew/bin"
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
        <string>$program</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$IN_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$ffmpeg_dir:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>SHRINKIT_DIR</key>
        <string>$BASE_DIR</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
  print -r -- "==> Installed launchd agent: $PLIST"
}

# The working folder itself stays outside the privacy-protected locations, so the Desktop gets a
# shortcut to it rather than the folder. A real folder already sitting on that name is never
# touched: it is somebody's own, and replacing it would take their files with it.
setup_desktop_link() {
  local link="$HOME/Desktop/${BASE_DIR:t}"
  [[ "$BASE_DIR" == "$HOME/Desktop/"* ]] && return 0
  if [[ -e "$link" && ! -L "$link" ]]; then
    print -r -- "!! $link already exists as a real folder; skipping the Desktop shortcut."
    return 0
  fi
  ln -sfn "$BASE_DIR" "$link"
  print -r -- "==> Desktop shortcut: $link -> $BASE_DIR"
}

# Rebuilt from the presets folder every run, so a preset that was deleted leaves no entry behind.
setup_actions() {
  local stale preset name
  local -a installed
  mkdir -p "$SERVICES_DIR"
  for stale in "$SERVICES_DIR"/shrinkit:*.workflow(N); do rm -rf "$stale"; done
  for preset in "$PRESET_DIR"/*.conf(N.); do
    name="${preset:t:r}"
    install_preset_action "$name" > /dev/null && installed+=("$name")
  done
  install_cuts_action > /dev/null
  install_merge_action > /dev/null
  print -r -- "==> Finder entries, one per preset, plus 'shrinkit: mark cuts' and 'shrinkit: merge': ${installed[*]}"
}

# A checkout registers the script that is running rather than a copy of it, so a git pull is picked
# up without anyone remembering to reinstall. The symlink is what the agent and the menu entries
# name, which keeps "shrinkit" on the PATH and keeps Login Items reading "shrinkit" rather than
# "shrinkit.sh". A keg needs none of it: brew puts its own shrinkit on the PATH.
# A checkout inside Desktop, Documents or Downloads cannot be reached by the agent or by a Finder
# entry at all, link or no link: both run without the privacy grant that a folder there needs, and
# zsh reports "can't open input file". Measured on a checkout in ~/Desktop, where a dropped
# recording sat in input/ untouched and the right-click entry failed, while the same install run
# from outside processed it within seconds. So a guarded checkout is copied out instead of linked
# to, into a ~/.local laid out exactly like a Homebrew prefix, which lib_dir() and data_dir()
# already know how to read.
setup_bin() {
  local link="$BIN_DIR/shrinkit" share="$SHARE_DIR"
  # Under Homebrew a copy or a link that an earlier checkout install left in ~/.local would still
  # answer to "shrinkit" wherever ~/.local/bin sits first on the PATH, so it goes: brew's is the
  # one registered now.
  # Only what an earlier setup put there, recognised by the script's own opening line and by lib/
  # in the share folder: this runs on every brew install and upgrade, so a file of somebody else's
  # that merely has the same name has to survive it.
  if installed_by_brew; then
    local -a retired
    grep -q '^# Shrinks screen recordings dropped into the input folder' "$link" 2> /dev/null \
      && rm -f "$link" && retired+=("$link")
    [[ -f "$share/lib/setup.zsh" ]] && rm -rf "$share" && retired+=("$share")
    ((${#retired})) \
      && print -r -- "==> Removed the earlier install, Homebrew's shrinkit is the one in use now: ${(j:, :)retired}"
    return 0
  fi
  mkdir -p "$BIN_DIR"

  if guarded_path "$SELF"; then
    rm -rf "$share"
    mkdir -p "$share"
    # rm first: cp onto an existing symlink writes through it to whatever it points at, leaving
    # the link in place and the copy somewhere nobody asked for. That is the shape an upgrade from
    # the version that linked always takes.
    rm -f "$link"
    cp "$SELF" "$link" && chmod +x "$link" || {
      print -u2 -r -- "!! could not copy the script to $link"
      return 1
    }
    cp -R "$LIB_DIR" "$share/lib" || return 1
    cp -R "$REPO_DIR/presets" "$REPO_DIR/quick-action" "$REPO_DIR/settings.conf" "$share/" || return 1
    print -r -- "==> Copied to $link, since $SELF is in a privacy-protected folder"
    print -r -- "    A git pull there no longer reaches the installed copy; run setup again after one."
    return 0
  fi

  # An old install whose checkout is gone leaves this file as the only shrinkit there is, and it is
  # then what is running: ln -sfn would unlink it and leave a link pointing at itself, which is the
  # end of that install. Resolved on both sides, since $SELF is and $link is not: with a home
  # directory behind a symlink of its own the two spell the same file differently, the guard misses,
  # and the script deletes itself. Measured under /tmp, which is such a path on macOS. Below the
  # guarded branch, not above it: a link already pointing at a guarded checkout is exactly what an
  # upgrade from the version that always linked arrives with, and it still has to become a copy.
  [[ "${link:A}" == "$SELF" ]] && return 0
  # A file the user can see changes kind here, from a copy of the script to a link to it.
  [[ -f "$link" && ! -L "$link" ]] \
    && print -r -- "==> Replacing the copy at $link with a link to this script"
  ln -sfn "$SELF" "$link"
  print -r -- "==> On your PATH: $link -> $SELF"
}

# Two installs answering to one command name: a Homebrew keg sits on the PATH ahead of ~/.local/bin
# on a default macOS setup, so installing one while the other is registered splits the tool across
# its entry points. The agent and the Finder entries keep running the path in the plist while the
# terminal runs the other one, and nothing anywhere says so. Neither install can safely remove the
# other, so this only reports it.
warn_about_another_shrinkit() {
  local registered="$1" onpath
  onpath="$(command -v shrinkit 2> /dev/null)" || return 0
  [[ -n "$onpath" && "${onpath:A}" != "${registered:A}" ]] || return 0
  print -r -- ""
  print -r -- "!! 'shrinkit' on your PATH is $onpath"
  print -r -- "   but the agent and the Finder entries now run $registered."
  # Not "tear down the one you do not want": teardown unregisters whatever is registered and
  # clears ~/.local whichever binary runs it, so following that from the keg deletes the checkout
  # install instead of the keg. It cannot act on a preference, so it must not be offered one.
  print -r -- "   Two installs are in play. 'shrinkit teardown' unregisters the agent and the menu"
  print -r -- "   entries and clears ~/.local whichever one you run it from; afterwards run 'setup'"
  print -r -- "   again from the one you mean to keep."
}

setup_agent() {
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
  "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"
}

full_disk_access_note() {
  local program="$1"
  cat << FDA

------------------------------------------------------------------------
ONE-TIME STEP: $BASE_DIR is in a macOS privacy-protected location.
A background job cannot write there until you grant it Full Disk Access:

  1. Open  System Settings > Privacy & Security > Full Disk Access
  2. Click the + button (authenticate if asked)
  3. Press Cmd+Shift+G and paste:  $program
  4. Add it, and make sure its switch is ON
  5. Run this to restart the agent:
       shrinkit setup

Until then, recordings dropped in input/ will not be processed.
------------------------------------------------------------------------
FDA
}

setup_command() {
  print -r -- "==> Base folder: $BASE_DIR"
  # A folder named for this run is remembered, so an install that runs setup again without it, as
  # brew does on every upgrade, keeps the folder instead of falling back to the default.
  [[ -n "${SHRINKIT_DIR-}" ]] && save_folder "$BASE_DIR"

  if [[ ! -x "$FFMPEG" ]]; then
    if command -v brew > /dev/null 2>&1; then
      print -r -- "==> Installing ffmpeg via Homebrew (this can take a few minutes)..."
      brew install ffmpeg || return 1
      FFMPEG="$(find_tool ffmpeg)"
      FFPROBE="$(find_tool ffprobe)"
    else
      print -u2 -r -- "!! ffmpeg is required and Homebrew was not found."
      print -u2 -r -- "!! Install Homebrew from https://brew.sh then run: brew install ffmpeg"
      return 1
    fi
  fi
  print -r -- "==> Using ffmpeg at $FFMPEG"

  setup_folders
  setup_presets
  setup_config
  setup_bin
  # After the symlink, since that is the path the agent and the entries are told to run.
  local program
  program="$(registered_path)"
  setup_plist "$program"
  setup_desktop_link
  setup_actions
  setup_agent

  print -r -- ""
  print -r -- "Done. Open the '${BASE_DIR:t}' shortcut on your Desktop:"
  print -r -- "  - drop recordings into  $IN_DIR"
  print -r -- "  - pick up results from  $OUT_DIR"
  print -r -- "  - change behaviour by editing  $CONFIG"
  warn_about_another_shrinkit "$program"
  needs_full_disk_access && full_disk_access_note "$program"
  return 0
}

# The folder the agent was actually registered with, read back from the plist that names it.
# Tearing down an install made with SHRINKIT_DIR set, without setting it again, used to leave that
# folder's Desktop shortcut behind.
registered_base() {
  local from_plist
  from_plist="$(plutil -extract EnvironmentVariables.SHRINKIT_DIR raw -o - "$PLIST" 2> /dev/null)"
  [[ -n "$from_plist" ]] && print -r -- "$from_plist" || print -r -- "$BASE_DIR"
}

# Every branch below reports only what it actually found, because the shapes differ: a keg install
# has no PATH entry of ours and no copy under ~/.local/share, and a base folder on the Desktop has
# no shortcut. Claiming all of it every time taught anyone reading the output to ignore it.
teardown_command() {
  local base link action entries=0 unloaded=0 had_plist=0
  local -a removed failed
  base="$(registered_base)"

  # launchd refuses to boot out a service it never loaded, so the status says whether one was
  # running. Read rather than swallowed: with the plist deleted by hand and the agent still
  # bootstrapped, reporting off the file alone claimed there was no agent in the same breath as
  # unloading one.
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2> /dev/null && unloaded=1
  [[ -f "$PLIST" ]] && {
    rm -f "$PLIST" && had_plist=1 || failed+=("$PLIST")
  }
  ((unloaded || had_plist)) && removed+=("the agent")

  # brew puts nothing in ~/.local, so whatever is here is setup's link, an older install's copy, or
  # the parts that come with such a copy. A keg's own binary belongs to brew uninstall.
  link="$BIN_DIR/shrinkit"
  [[ -e "$link" || -L "$link" ]] && {
    rm -f "$link" && removed+=("$link") || failed+=("$link")
  }
  # Written by setup_bin when the checkout it ran from was privacy-protected. Left behind until
  # now, which made an uninstall that said it was finished leave 48K of the tool on disk.
  [[ -d "$SHARE_DIR" ]] && {
    rm -rf "$SHARE_DIR" && removed+=("$SHARE_DIR") || failed+=("$SHARE_DIR")
  }

  # Only ever a shortcut, never a real folder somebody put there.
  [[ -L "$HOME/Desktop/${base:t}" ]] && {
    rm -f "$HOME/Desktop/${base:t}" && removed+=("the Desktop shortcut") || failed+=("$HOME/Desktop/${base:t}")
  }

  # The same entries setup builds and rebuilds, matched the same way, with the command they run
  # read as well so a menu entry of somebody else's is never swept up for its name alone.
  for action in "$SERVICES_DIR"/shrinkit:*.workflow(N); do
    grep -q "SHRINKIT_DIR=" "$action/Contents/document.wflow" 2> /dev/null && {
      rm -rf "$action" && ((++entries)) || failed+=("$action")
    }
  done
  ((entries)) && removed+=("$entries Finder entries")
  /System/Library/CoreServices/pbs -update 2> /dev/null || true

  if ((${#removed})); then
    print -r -- "Removed: ${(j:, :)removed}."
  elif ((!${#failed})); then
    print -r -- "Nothing to remove: no agent, no PATH entry, no shortcut and no Finder entries."
  fi
  # Exit status left at 0 on purpose: brew runs this as the cask's uninstall script and would refuse
  # to uninstall at all on a failure here, which leaves the user with less, not more.
  ((${#failed})) && print -u2 -r -- "!! Could not remove (delete by hand): ${(j:, :)failed}"
  print -r -- "Left in place (delete by hand if you want): $base"
}
