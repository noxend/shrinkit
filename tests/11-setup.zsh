# Sourced by tests/run-tests.sh: setup and teardown.

test_a_launchctl_call_without_a_stub_is_refused() {
  local out code=0
  # Asked for a listing only, so a broken guard reaches nothing but a read.
  out="$("$SHRINKIT_LAUNCHCTL" list com.shrinkit 2>&1)" || code=$?

  check "is refused" test "$code" = 99
  check "and says why" contains "$out" "without its stub"
}

test_setup_writes_a_folder_with_an_ampersand_into_a_valid_plist() {
  local box plist
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/R&D <draft>" > /dev/null 2>&1

  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "the plist parses" plutil -lint "$plist"
  check "and names the folder as it is" \
    test "$(plist_value "$plist" WatchPaths.0)" = "$box/R&D <draft>/input"
}

test_a_right_click_entry_takes_names_as_written() {
  local box folder cmd
  box="$(scratch)"
  setup_box "$box"
  folder="$box/w \$(touch folder-ran)"
  run_setup "$box" "$folder" > /dev/null 2>&1
  print -r -- 'notify = false' >> "$folder/settings.conf"
  cp "$folder/presets/2x.conf" "$folder/presets/x \$(touch preset-ran).conf"
  run_setup "$box" "$folder" > /dev/null 2>&1
  mkdir -p "$box/cwd" "$box/clips"
  cp "$FIXTURES/silent.mov" "$box/clips/clip.mov"
  cmd="$(action_command "$box/home/Library/Services/shrinkit: x \$(touch preset-ran).workflow")"

  # The way a Quick Action runs its command: zsh, with the selected files as arguments.
  (cd "$box/cwd" && HOME="$box/home" zsh -c "$cmd" zsh "$box/clips/clip.mov" > /dev/null 2>&1)

  check "runs nothing named in the folder" missing "$box/cwd/folder-ran"
  check "or in the preset" missing "$box/cwd/preset-ran"
  check "and shrinks with that preset" exists "$box/clips/clip-x \$(touch preset-ran).mp4"
}

test_setup_does_not_say_done_when_launchd_refuses_the_agent() {
  local box out code=0 brew_code=0
  box="$(scratch)"
  setup_box "$box"
  : > "$box/refuse"

  out="$(run_setup "$box" 2>&1)" || code=$?

  check "does not say it is done" lacks "$out" "Done."
  check "says the watcher was refused" contains "$out" "refused to start the watcher"
  check "and exits 1" test "$code" = 1

  # Under brew the answer stays 0: brew runs setup before it links the command, and a failure
  # there aborts the upgrade with the old version already torn down.
  brew_cask "$box"
  out="$(HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup 2>&1)" || brew_code=$?
  check "under brew it still says so" contains "$out" "refused to start the watcher"
  check "and lets brew finish" test "$brew_code" = 0
}

test_setup_registers_the_script_that_is_running() {
  local box plist
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "writes the agent" exists "$plist"
  check "watching the input folder" \
    test "$(plist_value "$plist" WatchPaths.0)" = "$box/work/input"
  check "carrying the working folder" \
    test "$(plist_value "$plist" EnvironmentVariables.SHRINKIT_DIR)" = "$box/work"
  # The installer used to copy the script and point the agent at the copy, so a git pull left the
  # agent running yesterday's version with nothing anywhere to say so.
  check "runs the link on the PATH" \
    test "$(plist_value "$plist" ProgramArguments.0)" = "$box/home/.local/bin/shrinkit"
  check "which is this very script" links_to "$box/home/.local/bin/shrinkit" "$OPTIMIZER"
  # The agent and the menu entries have to name the same program, or an upgrade or a move fixes
  # one and leaves the other pointing at nothing.
  check "and the menu entries name it too" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" \
    "$box/home/.local/bin/shrinkit"
  check "and hands the agent no data directory to go stale" \
    test -z "$(plist_value "$plist" EnvironmentVariables.SHRINKIT_REPO)"
}

test_setup_makes_the_folders_and_loads_the_agent() {
  local box dir
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  for dir in input output .processed .logs presets; do
    check "creates $dir/" test -d "$box/work/$dir"
  done
  check "installs the settings" exists "$box/work/settings.conf"
  check "links the Desktop shortcut" links_to "$box/home/Desktop/work" "$box/work"
  # Reloading rather than loading: bootstrap over an already-loaded label is an error, so a second
  # setup would fail without the bootout in front of it.
  check "boots the old agent out" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "then bootstraps the new one" \
    grep -q "^bootstrap gui/$(id -u) $box/home/Library/LaunchAgents/com.shrinkit.plist$" "$box/launchctl.log"
}

test_setup_builds_one_entry_per_preset_and_sweeps_the_rest() {
  local box services
  box="$(scratch)"
  setup_box "$box"
  services="$box/home/Library/Services"
  mkdir -p "$services"
  cp -R "$REPO_DIR/quick-action/shrinkit.workflow" "$services/shrinkit: gone.workflow"

  run_setup "$box" > /dev/null 2>&1

  # three stock presets, plus mark cuts and merge
  check "one entry per preset plus the two that are not presets" \
    test "$(action_count "$services")" = 5
  check "a preset that no longer exists leaves no entry" missing "$services/shrinkit: gone.workflow"
  check "and the preset entries are there" exists "$services/shrinkit: 2x.workflow/Contents/Info.plist"
}

test_setup_run_again_keeps_the_settings_and_the_presets() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  print -r -- "crf = 19" >> "$box/work/settings.conf"
  rm -f "$box/work/presets/tiny.conf"
  run_setup "$box" > /dev/null 2>&1

  check "never overwrites the settings" grep -q "crf = 19" "$box/work/settings.conf"
  check "and does not repopulate a preset you deleted" missing "$box/work/presets/tiny.conf"
  check "so its entry is gone too" missing "$box/home/Library/Services/shrinkit: tiny.workflow"
}

test_setup_never_replaces_a_real_folder_on_the_desktop() {
  local box
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/home/Desktop/work"
  print -r -- "mine" > "$box/home/Desktop/work/notes.txt"

  run_setup "$box" > /dev/null 2>&1

  check "leaves the folder as it found it" is_dir "$box/home/Desktop/work"
  check "with what was inside it" exists "$box/home/Desktop/work/notes.txt"
}

test_setup_replaces_an_older_installs_copy_with_a_link() {
  local box link
  box="$(scratch)"
  setup_box "$box"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "$link:h"
  print -r -- "#!/bin/zsh" > "$link"
  chmod +x "$link"

  run_setup "$box" > /dev/null 2>&1

  check "the stale copy becomes a link to the real script" links_to "$link" "$OPTIMIZER"
}

test_setup_run_from_the_path_link_leaves_itself_runnable() {
  local box link
  box="$(scratch)"
  setup_box "$box"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "${link:h}"
  cp "$OPTIMIZER" "$link"
  chmod +x "$link"
  cp -R "$REPO_DIR/quick-action" "$REPO_DIR/presets" "$REPO_DIR/settings.conf" "${link:h}/"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$link" setup > /dev/null 2>&1

  # The shape an install takes once its checkout is gone: this file is the only shrinkit left, and
  # it is the one running. Relinking it over itself leaves a link pointing at its own name, and
  # there is then no shrinkit at all.
  check "the script it was run from survives" test -f "$link"
  check "and is still a script" zsh -n "$link"
}

test_setup_points_the_privacy_grant_at_the_registered_binary() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  # Desktop, Documents and Downloads are the three macOS refuses a background job in until the
  # binary is granted Full Disk Access by hand.
  out="$(run_setup "$box" "$box/home/Desktop/clips" 2>&1)"

  check "says the one-time step is needed" contains "$out" "Full Disk Access"
  # Scoped to the line that carries the path to paste. Asserting against the whole output passes on
  # the "On your PATH" line setup prints earlier, whatever the note itself says.
  # The grant is per binary path. A note naming anything but the path the agent actually runs sends
  # the user to grant access to a file that is never the one refused.
  check "and names the path the agent runs" \
    contains "$(print -r -- "$out" | grep 'paste:')" "$box/home/.local/bin/shrinkit"
  check "no shortcut to a folder already on the Desktop" \
    missing "$box/home/Desktop/clips/clips"
}

# A checkout inside Desktop, Documents or Downloads, which is where people put a clone often
# enough that this is the common case rather than an edge one.
guarded_checkout() {
  local box="$1" where="$1/home/Desktop/repos/shrinkit"
  mkdir -p "${where:h}"
  cp "$OPTIMIZER" "$where/../shrinkit.sh" 2> /dev/null
  mkdir -p "$where"
  cp "$OPTIMIZER" "$where/shrinkit.sh"
  chmod +x "$where/shrinkit.sh"
  cp -R "$REPO_DIR/lib" "$REPO_DIR/presets" "$REPO_DIR/quick-action" "$REPO_DIR/settings.conf" "$where/"
  print -r -- "$where/shrinkit.sh"
}

test_setup_copies_a_checkout_out_of_a_privacy_protected_folder() {
  local box script
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$script" setup > /dev/null 2>&1

  # Neither the agent nor a Finder entry can read a file in there, link or no link: zsh answers
  # "can't open input file" and nothing says why. Measured on a real checkout in ~/Desktop, where a
  # dropped recording sat unprocessed until the same install ran from outside.
  check "leaves a real file on the PATH, not a link into the folder" \
    test -f "$box/home/.local/bin/shrinkit" -a ! -L "$box/home/.local/bin/shrinkit"
  check "with the parts beside it, laid out like a prefix" \
    test -f "$box/home/.local/share/shrinkit/lib/merge.zsh"
  check "and the data too" test -f "$box/home/.local/share/shrinkit/quick-action/shrinkit.workflow/Contents/Info.plist"
}

test_setup_points_the_agent_and_the_entries_at_the_copy() {
  local box script plist
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$script" setup > /dev/null 2>&1

  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "the agent runs the copy" \
    test "$(plist_value "$plist" ProgramArguments.0)" = "$box/home/.local/bin/shrinkit"
  check "and never the guarded checkout" \
    lacks "$(plist_value "$plist" ProgramArguments.0)" "/Desktop/"
  check "the menu entries run the copy too" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" \
    "$box/home/.local/bin/shrinkit"
  check "and never the guarded checkout either" \
    lacks "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "/Desktop/repos"
}

test_setup_replaces_a_link_left_by_an_older_install_with_the_copy() {
  local box script link
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "${link:h}"
  ln -sfn "$script" "$link"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$script" setup > /dev/null 2>&1

  # cp onto a symlink writes through it and leaves the link alone, which is exactly the shape an
  # upgrade from the version that always linked arrives in.
  check "the link becomes a real file" test ! -L "$link"
  check "and the copy runs" test -x "$link"
}

test_setup_says_when_another_shrinkit_answers_on_the_path() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/otherbin"
  print -r -- '#!/bin/zsh' > "$box/otherbin/shrinkit"
  chmod +x "$box/otherbin/shrinkit"

  # What Homebrew's bin does on a default macOS PATH, where /opt/homebrew/bin comes before ~/.local/bin.
  out="$(PATH="$box/otherbin:$PATH" HOME="$box/home" SHRINKIT_DIR="$box/work" \
    SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" setup 2>&1)"

  check "names the one the terminal would run" contains "$out" "$box/otherbin/shrinkit"
  check "and the one the agent will run" \
    contains "$out" "now run $box/home/.local/bin/shrinkit"
  check "and says both are in play" contains "$out" "Two installs are in play"
  # teardown clears ~/.local whichever binary runs it, so telling anyone to tear down "the one you
  # do not want" sends them to delete the install they meant to keep.
  check "and never offers to tear down one of them" lacks "$out" "do not want"
  check "but says to set up the one to keep" contains "$out" "run 'setup'"
}

test_setup_stays_quiet_when_the_path_agrees_with_what_it_registered() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  out="$(PATH="$box/home/.local/bin:$PATH" HOME="$box/home" SHRINKIT_DIR="$box/work" \
    SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" setup 2>&1)"

  check "says nothing about a second install" lacks "$out" "Two installs"
  # Pins the quiet branch rather than just the absence of a word: a warning that crashed, or a
  # setup that stopped before reaching it, would read as silence too.
  check "and got to the end of setup" contains "$out" "Done."
}

test_teardown_reports_an_agent_it_unloaded_without_a_plist() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  # The plist deleted by hand, the agent left bootstrapped. Reporting off the file alone said
  # there was no agent in the same breath as unloading one.
  rm -f "$box/home/Library/LaunchAgents/com.shrinkit.plist"

  out="$(run_teardown "$box" 2>&1)"

  check "boots it out" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "and says the agent went" contains "$out" "the agent"
  check "rather than claiming there was none" lacks "$out" "Nothing to remove"
}

test_a_cask_install_registers_the_link_that_survives_an_upgrade() {
  local box plist
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # The staged folder is named for the version and goes on the next upgrade, taking every entry
  # that names it along; brew repoints the bin link at the new one instead.
  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "the agent runs brew's link" test "$(plist_value "$plist" ProgramArguments.0)" = "${box:A}/brew/bin/shrinkit"
  check "and never the versioned folder" lacks "$(plist_value "$plist" ProgramArguments.0)" "Caskroom"
  check "the menu entry is built" test -d "$box/home/Library/Services/shrinkit: 2x.workflow"
  check "nor does a menu entry" \
    lacks "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "Caskroom"
  check "and it makes no PATH link of its own" missing "$box/home/.local/bin/shrinkit"
}

test_a_cask_install_retires_an_earlier_checkout_copy() {
  local box
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/.local/bin" "$box/home/.local/share/shrinkit"
  cp "$OPTIMIZER" "$box/home/.local/bin/shrinkit"
  cp -R "$REPO_DIR/lib" "$box/home/.local/share/shrinkit/"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # Left in place, the old copy answers to "shrinkit" wherever ~/.local/bin comes first on the PATH
  # while the agent and the menu run brew's.
  check "removes the old copy on the PATH" missing "$box/home/.local/bin/shrinkit"
  check "and the parts that came with it" missing "$box/home/.local/share/shrinkit"
}

test_a_cask_install_leaves_a_different_shrinkit_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/.local/bin"
  print -rl -- '#!/bin/sh' 'echo somebody else' > "$box/home/.local/bin/shrinkit"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # This runs on every brew install and upgrade, so a file that only shares the name survives it.
  check "keeps a file that is not this script" grep -q "somebody else" "$box/home/.local/bin/shrinkit"
}
