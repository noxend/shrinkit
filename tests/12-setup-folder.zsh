# Sourced by tests/run-tests.sh: setup under brew, config folder, teardown.

# setup the way Homebrew runs it: `env -i` with a short whitelist, so SHRINKIT_DIR never arrives.
setup_as_brew_does() {
  local box="$1"
  env -i HOME="$box/home" PATH="$PATH" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    SHRINKIT_PBS="$SHRINKIT_PBS" zsh "$OPTIMIZER" setup
}

test_a_folder_named_once_survives_a_setup_without_it() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/clips" > /dev/null 2>&1
  run_teardown "$box" > /dev/null 2>&1

  # What brew upgrade does: teardown from the old version, then setup with SHRINKIT_DIR cleared.
  setup_as_brew_does "$box" > /dev/null 2>&1

  check "the agent still watches the folder that was chosen" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/clips/input"
  check "and no default folder was made instead" missing "$box/home/Movies/shrinkit"
}

test_config_folder_refuses_a_folder_it_cannot_write_to() {
  local box code=0
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  mkdir -p "$box/readonly"
  chmod 555 "$box/readonly" # what a read-only NTFS drive or a folder owned by root looks like

  HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    zsh "$OPTIMIZER" config folder "$box/readonly" > /dev/null 2>&1 || code=$?
  chmod 755 "$box/readonly"

  check "says no" test "$code" != 0
  check "keeps the folder it had" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/work/input"
  check "and keeps every menu entry" test "$(action_count "$box/home/Library/Services")" = 6
}

test_setup_under_brew_does_not_fail_the_upgrade_for_a_missing_drive() {
  local box code=0 out
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/Library/Application Support/shrinkit"
  print -r -- /Volumes/shrinkit-no-such-drive/work > "$box/home/Library/Application Support/shrinkit/folder"

  out="$(env -i HOME="$box/home" PATH="$PATH" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    SHRINKIT_PBS="$SHRINKIT_PBS" "$box/brew/bin/shrinkit" setup 2>&1)" || code=$?

  # brew runs setup before it links the command; a failure aborts the upgrade after the old
  # version was already torn down, leaving nothing at all to run setup with later.
  check "lets brew finish" test "$code" = 0
  check "registers nothing" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "and says how to finish once the drive is back" contains "$out" "run 'shrinkit setup'"
}

test_setup_does_not_point_at_a_shortcut_it_did_not_make() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/pictures/work"
  ln -s "$box/pictures/work" "$box/home/Desktop/work"

  out="$(run_setup "$box" 2>&1)"

  check "does not send anyone to that shortcut" lacks "$out" "Open the 'work' shortcut"
  check "names the folder instead" contains "$out" "The working folder is $box/work"
}

test_the_agent_uses_the_per_user_temporary_folder() {
  local box work expected
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  expected="$(getconf DARWIN_USER_TEMP_DIR)"

  # launchd gives the agent no TMPDIR; /tmp is shared by every account, this folder is not.
  env -u TMPDIR SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1

  check "the result lands" exists "$work/clip.mp4"
  check "made in the per-user temporary folder" logged "$box" "to '${expected%/}/shrinkit."
}

test_config_folder_moves_the_install_to_the_new_folder() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  print -r -- "crf = 19" >> "$box/work/settings.conf"

  out="$(HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" config folder "$box/elsewhere" 2>&1)"

  check "the agent watches the new folder" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/elsewhere/input"
  check "the menu entries work in it" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "SHRINKIT_DIR='$box/elsewhere'"
  check "the Desktop shortcut follows" links_to "$box/home/Desktop/elsewhere" "$box/elsewhere"
  check "and the old one is gone" missing "$box/home/Desktop/work"
  check "the old folder and what is in it stay" grep -q "crf = 19" "$box/work/settings.conf"
  check "and it says so" contains "$out" "stay there"
  check "the settings go along" grep -q "crf = 19" "$box/elsewhere/settings.conf"
  check "and the presets" exists "$box/elsewhere/presets/2x.conf"
  check "setup names the shortcut it made" contains "$out" "Open the 'elsewhere' shortcut"
  check "an upgrade keeps it" test "$(setup_as_brew_does "$box" 2>&1 | grep -c "Base folder: $box/elsewhere")" = 1
  check "and config folder names it" \
    test "$(HOME="$box/home" zsh "$OPTIMIZER" config folder)" = "$box/elsewhere"
}

test_teardown_leaves_a_different_shrinkit_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/.local/bin" "$box/home/.local/share/shrinkit"
  print -rl -- '#!/bin/sh' 'echo somebody else' > "$box/home/.local/bin/shrinkit"
  print -r -- "notes" > "$box/home/.local/share/shrinkit/notes.txt"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" teardown > /dev/null 2>&1

  # brew runs teardown on every upgrade, so a stranger's file with this name would go every time.
  check "keeps a file that is not this script" grep -q "somebody else" "$box/home/.local/bin/shrinkit"
  check "and a share folder that is not ours" exists "$box/home/.local/share/shrinkit/notes.txt"
}

test_a_folder_an_older_install_registered_survives_the_first_cask_setup() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/clips" > /dev/null 2>&1
  print -r -- "crf = 19" >> "$box/clips/settings.conf"
  # v2 named the folder only in the agent's plist; there was no file to remember it in.
  rm -rf "$box/home/Library/Application Support/shrinkit"

  setup_as_brew_does "$box" > /dev/null 2>&1

  check "the agent still watches that folder" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/clips/input"
  check "no default folder was made instead" missing "$box/home/Movies/shrinkit"
  check "and it is remembered from now on" \
    test "$(< "$box/home/Library/Application Support/shrinkit/folder")" = "$box/clips"
}

test_config_folder_refuses_a_folder_it_cannot_create() {
  local box code=0
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    zsh "$OPTIMIZER" config folder /Volumes/shrinkit-no-such-drive/work > /dev/null 2>&1 || code=$?

  # A drive that is not connected used to be saved, registered and reported as done, and the
  # preset entries were rebuilt from a presets folder that was not there.
  check "says no" test "$code" != 0
  check "keeps the folder it had" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/work/input"
  check "remembers the folder it had" \
    test "$(< "$box/home/Library/Application Support/shrinkit/folder")" = "$box/work"
  check "and keeps every menu entry" test "$(action_count "$box/home/Library/Services")" = 6
}

test_setup_registers_nothing_for_a_folder_it_cannot_create() {
  local box code=0
  box="$(scratch)"
  setup_box "$box"

  run_setup "$box" /Volumes/shrinkit-no-such-drive/work > /dev/null 2>&1 || code=$?

  check "fails" test "$code" != 0
  check "registers no agent" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "and builds no menu" test "$(action_count "$box/home/Library/Services")" = 0
}

test_config_folder_does_not_recreate_a_folder_moved_away_by_hand() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/old" > /dev/null 2>&1
  mv "$box/old" "$box/moved"

  out="$(HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" config folder "$box/moved" 2>&1)"

  check "the old path stays gone" missing "$box/old"
  check "and nothing claims recordings are waiting there" lacks "$out" "stay there"
  check "the agent watches the folder it was moved to" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/moved/input"
}

test_config_folder_moves_the_shortcut_after_a_move_by_hand_to_the_same_name() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/one/shrinkit" > /dev/null 2>&1
  mkdir -p "$box/two"
  mv "$box/one/shrinkit" "$box/two/shrinkit" # moved in Finder; the shortcut now leads nowhere

  HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    zsh "$OPTIMIZER" config folder "$box/two/shrinkit" > /dev/null 2>&1

  check "the shortcut leads to the folder again" links_to "$box/home/Desktop/shrinkit" "$box/two/shrinkit"
}

test_a_desktop_link_of_somebody_elses_is_left_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/pictures/work"
  ln -s "$box/pictures/work" "$box/home/Desktop/work"

  run_setup "$box" > /dev/null 2>&1
  check "setup does not repoint it" links_to "$box/home/Desktop/work" "$box/pictures/work"
  run_teardown "$box" > /dev/null 2>&1
  check "teardown does not remove it" links_to "$box/home/Desktop/work" "$box/pictures/work"
}

test_the_agent_also_runs_when_it_is_loaded() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  # A recording that arrived while the agent was not loaded is picked up at login.
  check "at load" test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" RunAtLoad)" = true
}

test_teardown_removes_the_copy_setup_made_out_of_a_guarded_checkout() {
  local box script out
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$script" setup > /dev/null 2>&1
  check "the copy is there to begin with" exists "$box/home/.local/share/shrinkit/lib/merge.zsh"

  out="$(run_teardown "$box" "$box/work" 2>&1)"

  # An uninstall that says it is finished while 48K of the tool sits under ~/.local is not one.
  check "takes the parts with it" missing "$box/home/.local/share/shrinkit"
  check "and the copy on the PATH" missing "$box/home/.local/bin/shrinkit"
  check "and says where they went" contains "$out" "$box/home/.local/share/shrinkit"
}

test_teardown_under_brew_claims_no_path_entry_of_its_own() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1
  out="$(HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" teardown 2>&1)"

  # setup_bin makes no link under brew, so naming one here taught anyone reading the output that
  # the list is boilerplate rather than a report.
  check "removes the agent" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "and does not name a PATH entry it never made" lacks "$out" "the PATH link"
  check "nor one under ~/.local at all" lacks "$out" "$box/home/.local/bin"
  check "and leaves brew's own files alone" exists "$box/brew/Caskroom/shrnkit/9.9/shrinkit-9.9/shrinkit.sh"
}

test_teardown_with_nothing_installed_says_so() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  out="$(run_teardown "$box" "$box/work" 2>&1)"

  check "reports that there was nothing here" contains "$out" "Nothing to remove"
  check "and still says what it left alone" contains "$out" "$box/work"
}

test_teardown_does_not_report_what_it_could_not_remove() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  # A Desktop that refuses the delete, the way a sandbox or a missing privacy grant does.
  chmod a-w "$box/home/Desktop"

  out="$(run_teardown "$box" 2>&1)"
  chmod u+w "$box/home/Desktop"

  check "the shortcut is still there" test -L "$box/home/Desktop/work"
  check "and the report does not claim it" lacks "$out" "the Desktop shortcut"
  check "but names it as left behind" contains "$out" "Could not remove (delete by hand): $box/home/Desktop/work"
  check "while what it could remove is reported" contains "$out" "the agent"
}

test_teardown_finds_the_folder_it_registered_without_being_told() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/elsewhere" > /dev/null 2>&1
  check "the shortcut is there to begin with" links_to "$box/home/Desktop/elsewhere" "$box/elsewhere"

  # No SHRINKIT_DIR: the plist it is about to delete is the only thing that still knows.
  run_teardown "$box" > /dev/null 2>&1

  check "removes the agent" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "boots it out first" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "removes the PATH link" missing "$box/home/.local/bin/shrinkit"
  check "removes that folder's Desktop shortcut" missing "$box/home/Desktop/elsewhere"
  check "removes the Finder entries" test "$(action_count "$box/home/Library/Services")" = 0
}

test_teardown_leaves_the_recordings_and_the_settings_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/elsewhere" > /dev/null 2>&1
  print -r -- "crf = 19" >> "$box/elsewhere/settings.conf"
  cp "$FIXTURES/silent.mov" "$box/elsewhere/input/clip.mov"

  run_teardown "$box" > /dev/null 2>&1

  check "keeps the settings" grep -q "crf = 19" "$box/elsewhere/settings.conf"
  check "keeps what was waiting to be processed" exists "$box/elsewhere/input/clip.mov"
  check "and the presets" exists "$box/elsewhere/presets/2x.conf"
}

test_teardown_never_takes_a_real_folder_off_the_desktop() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  rm -f "$box/home/Desktop/work"
  mkdir -p "$box/home/Desktop/work"

  run_teardown "$box" > /dev/null 2>&1

  check "leaves it where it is" is_dir "$box/home/Desktop/work"
}
