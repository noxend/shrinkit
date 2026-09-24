# Sourced by tests/run-tests.sh: doctor's check of the launchd agent.

test_doctor_fails_when_nothing_was_set_up() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  out="$(run_doctor "$box" 2>&1)"

  check "fails, saying there is no agent" contains "$(doctor_line "$out" watcher)" "FAIL  watcher        not installed"
  check "and how to install it" contains "$(doctor_block "$out" watcher)" "  shrinkit setup"
}

test_doctor_fails_when_the_plist_is_not_valid() {
  local box out plist
  box="$(installed_box)"
  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  head -c 200 "$plist" > "$box/cut" && mv "$box/cut" "$plist" # a plist cut short

  out="$(run_doctor "$box" 2>&1)"

  check "fails, saying the plist is damaged" \
    test "$(doctor_line "$out" watcher)" = "FAIL  watcher        $plist is not a valid plist"
}

test_doctor_fails_when_the_program_is_gone() {
  local box out
  box="$(installed_box)"
  rm -f "$box/home/.local/bin/shrinkit"
  print -r -- $((78 << 8)) > "$box/last-exit" # what launchd keeps after failing to start it

  out="$(run_doctor "$box" 2>&1)"

  check "fails, naming the program" test "$(doctor_line "$out" watcher)" = \
    "FAIL  watcher        it runs $box/home/.local/bin/shrinkit, which is not there"
  check "says how to register one that is" contains "$(doctor_block "$out" watcher)" "  shrinkit setup"
  check "without blaming the log files for the 78" lacks "$out" "log files"
}

test_doctor_fails_when_the_program_cannot_be_run() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1
  chmod -x "$box/brew/Caskroom/shrnkit/9.9/shrinkit-9.9/shrinkit.sh"

  out="$(run_doctor "$box" 2>&1)"

  check "fails, saying it cannot be run" contains "$(doctor_line "$out" watcher)" "which is not executable"
  check "and how to fix it" contains "$(doctor_block "$out" watcher)" "  chmod +x '${box:A}/brew/bin/shrinkit'"
}

test_doctor_fails_when_the_agent_is_not_loaded() {
  local box out code=0
  box="$(installed_box)"
  "$box/stub/launchctl" bootout "gui/$(id -u)/com.shrinkit"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "fails" test "$(doctor_line "$out" watcher)" = "FAIL  watcher        installed, but macOS is not running it"
  check "names the likely cause" contains "$(doctor_block "$out" watcher)" "Login Items"
  check "says how to start it again" contains "$(doctor_block "$out" watcher)" "  shrinkit setup"
  check "and exits 1" test "$code" = 1
}

test_doctor_explains_how_the_last_run_ended() {
  local box out raw
  local -A says
  box="$(installed_box)"
  says=(
    $((78 << 8)) "macOS could not start it (exit 78)"
    $((127 << 8)) "could not read $box/home/.local/bin/shrinkit (exit 127)"
  )

  for raw in "${(@k)says}"; do
    print -r -- "$raw" > "$box/last-exit"
    out="$(run_doctor "$box" 2>&1)"
    check "fails for a last exit of $((raw >> 8))" \
      test "$(doctor_line "$out" watcher)" = "FAIL  watcher        ${says[$raw]}"
  done
}

test_doctor_ignores_a_last_exit_from_before_the_run_going_on_now() {
  local box out
  box="$(installed_box)"
  # launchd keeps the status of the run before while the next one is going.
  print -r -- $((78 << 8)) > "$box/last-exit"
  print -r -- 4242 > "$box/pid"

  out="$(run_doctor "$box" 2>&1)"

  check "passes the watcher" verdict_is "$out" watcher ok
}

test_doctor_does_not_judge_the_watcher_from_another_session() {
  local box out
  box="$(installed_box)"
  "$box/stub/launchctl" bootout "gui/$(id -u)/com.shrinkit"
  print -r -- Background > "$box/session" # an ssh login, say, which sees another launchd domain

  out="$(run_doctor "$box" 2>&1)"

  check "warns that it cannot tell" test "$(doctor_line "$out" watcher)" = \
    "warn  watcher        cannot tell from this session whether macOS runs it"
}
