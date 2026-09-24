# Sourced by tests/run-tests.sh: doctor's report, and which shrinkit it is.

test_doctor_finds_nothing_wrong_with_a_fresh_install() {
  local box out code=0
  box="$(installed_box)"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "names the shrinkit that is running" \
    test "$(doctor_line "$out" command)" = "ok    command        $OPTIMIZER (a clone)"
  check "finds ffmpeg where shrinkit looks" \
    test "$(doctor_line "$out" ffmpeg)" = "ok    ffmpeg         $FFMPEG"
  check "says there is nothing wrong" test "${${(f)out}[-1]}" = "No problems found."
  check "and exits 0" test "$code" = 0
}

test_doctor_names_a_cask_install_as_homebrews() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  out="$(env -u SHRINKIT_DIR HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    PATH="$(clean_path "$box/brew/bin")" "$box/brew/bin/shrinkit" doctor 2>&1)"

  # The path brew keeps pointing at the current version, never the versioned folder under Caskroom.
  check "names brew's link and says it is Homebrew's" \
    test "$(doctor_line "$out" command)" = "ok    command        ${box:A}/brew/bin/shrinkit (Homebrew)"
}

test_doctor_leaves_everything_as_it_found_it() {
  local box before after calls out
  box="$(installed_box)"
  # A setting a run would write a log line about, and a recording waiting to be picked up: the
  # two things doctor reads that a run would write for.
  print -r -- 'output_suffix = -2x' >> "$box/work/settings.conf"
  cp "$FIXTURES/silent.mov" "$box/work/input/clip.mov"
  calls="$(wc -l < "$box/launchctl.log")"
  before="$(listing "$box")"

  out="$(run_doctor "$box" 2>&1)"

  after="$(listing "$box")"
  check "ran its checks" contains "$out" "ok    command"
  check "and changed no file or folder" test "$before" = "$after"
  check "and asked launchd for nothing" test -z "$(tail -n "+$((calls + 1))" "$box/launchctl.log")"
}

test_doctor_refuses_an_argument_it_does_not_take() {
  local box out code=0
  box="$(scratch)"
  setup_box "$box"

  out="$(env -u SHRINKIT_DIR HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    zsh "$OPTIMIZER" doctor --fix 2>&1)" || code=$?

  check "exits 2" test "$code" = 2
  check "says how it is used" contains "$out" "usage: doctor"
  check "and checks nothing" lacks "$out" "ffmpeg"
}

test_doctor_warns_when_another_shrinkit_comes_first_on_the_path() {
  local box out code=0
  # A space in every path, so the commands doctor prints have to be quoted to paste.
  box="$(scratch)/two words"
  setup_box "$box"
  brew_cask "$box"
  run_setup "$box" > /dev/null 2>&1

  # Homebrew's doctor, run where the clone's link comes first on the PATH.
  out="$(env -u SHRINKIT_DIR HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    PATH="$(clean_path "$box/home/.local/bin" "$box/brew/bin")" "$box/brew/bin/shrinkit" doctor 2>&1)" || code=$?

  check "warns that two installs are in play" \
    test "$(doctor_line "$out" command)" = "warn  command        two installs are in play"
  check "naming the one the PATH finds" \
    contains "$(doctor_block "$out" command)" "'shrinkit' on your PATH is $box/home/.local/bin/shrinkit"
  check "and what the watcher runs" \
    contains "$(doctor_block "$out" command)" "the watcher runs $box/home/.local/bin/shrinkit"
  check "says how to keep this one" contains "$out" "  '${box:A}/brew/bin/shrinkit' setup"
  check "or the other" contains "$out" "  '$box/home/.local/bin/shrinkit' setup"
  check "and exits 0" test "$code" = 0
}

test_doctor_warns_when_the_watcher_runs_another_install() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # A clone's doctor, run beside a Homebrew install that owns the agent and the menu.
  out="$(run_doctor "$box" 2>&1)"

  check "warns" verdict_is "$out" command warn
  check "naming what the watcher runs" \
    contains "$(doctor_block "$out" command)" "the watcher runs ${box:A}/brew/bin/shrinkit"
}

test_doctor_takes_the_copy_of_a_guarded_checkout_for_the_checkout() {
  local box script out
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$script" setup > /dev/null 2>&1

  out="$(env -u SHRINKIT_DIR HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    PATH="$(clean_path "$box/home/.local/bin")" "$script" doctor 2>&1)"

  # setup registers a copy in ~/.local for a checkout in Desktop, which nothing launchd runs may
  # read, and running setup there again only makes the same copy.
  check "does not call the copy a second install" verdict_is "$out" command ok
}
