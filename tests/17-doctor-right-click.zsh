# Sourced by tests/run-tests.sh: doctor's check of the right-click entries.

test_doctor_fails_when_a_preset_entry_lost_its_preset() {
  local box out code=0
  box="$(installed_box)"
  rm -f "$box/work/presets/tiny.conf" # a preset deleted in Finder

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "fails, naming the entry and the preset" test "$(doctor_line "$out" right-click)" = \
    "FAIL  right-click    right-click tiny runs the preset tiny, which is not in $box/work/presets"
  check "says how to rebuild the entries" contains "$(doctor_block "$out" right-click)" "  shrinkit setup"
  check "and exits 1" test "$code" = 1
}

test_doctor_warns_about_entries_that_are_missing() {
  local box out code=0
  box="$(installed_box)"
  # A preset made after setup and never given an entry, and an entry deleted by hand.
  print -r -- 'speed = 3' > "$box/work/presets/quick one.conf"
  rm -rf "$box/home/Library/Services/shrinkit: merge.workflow" "$box/home/Library/Services/shrinkit: edit.workflow"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "warns about the preset with no entry" \
    contains "$(doctor_block "$out" right-click)" "no right-click entry for the preset quick one"
  check "saying how to add it, quoted to paste" \
    contains "$(doctor_block "$out" right-click)" "  shrinkit preset install 'quick one'"
  check "and about the entries that went" contains "$(doctor_block "$out" right-click)" "no right-click entry for merge"
  check "edit among them" contains "$(doctor_block "$out" right-click)" "no right-click entry for edit"
  check "and exits 0" test "$code" = 0
}

# git pull without setup leaves 3.x's mark cuts entry in the menu, running a subcommand that only
# answers now.
test_doctor_warns_about_an_entry_an_older_shrinkit_left() {
  local box out entry code=0
  box="$(installed_box)"
  entry="$box/home/Library/Services/shrinkit: mark cuts.workflow"
  cp -R "$REPO_DIR/quick-action/shrinkit.workflow" "$entry"
  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string \
    "SHRINKIT_DIR=${(qq):-$box/work} ${(qq):-$box/home/.local/bin/shrinkit} mark-cuts \"\$@\"" \
    "$entry/Contents/document.wflow"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "warns, naming it as left from an older shrinkit" test "$(doctor_line "$out" right-click)" = \
    "warn  right-click    right-click mark cuts is left from an older shrinkit"
  check "says how to clear it" contains "$(doctor_block "$out" right-click)" "  shrinkit setup"
  check "and exits 0" test "$code" = 0
}

# shrinkit: edit opens its window on the launcher setup writes, so without it the entry opens
# nothing.
test_doctor_fails_the_edit_entry_without_its_launcher() {
  local box out launcher code=0
  box="$(installed_box)"
  launcher="$box/home/Library/Application Support/shrinkit/shrinkit edit.command"
  chmod a-x "$launcher"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "fails when Terminal cannot run it" test "$(doctor_line "$out" right-click)" = \
    "FAIL  right-click    right-click edit cannot open its window: $launcher is not executable"
  check "says how to write it again" contains "$(doctor_block "$out" right-click)" "  shrinkit setup"
  check "and exits 1" test "$code" = 1

  rm -f "$launcher"
  out="$(run_doctor "$box" 2>&1)"

  check "and when it is gone" test "$(doctor_line "$out" right-click)" = \
    "FAIL  right-click    right-click edit cannot open its window: there is no $launcher"
}

test_doctor_reads_an_entry_an_older_setup_wrote() {
  local box out entry
  box="$(installed_box)"
  # The command as setup wrote it before it quoted names: double quotes around each value.
  entry="$box/home/Library/Services/shrinkit: 2x.workflow"
  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string \
    "SHRINKIT_DIR=\"$box/work\" \"$box/home/.local/bin/shrinkit\" --preset \"2x\" \"\$@\"" \
    "$entry/Contents/document.wflow"

  out="$(run_doctor "$box" 2>&1)"

  check "counts it with the others" contains "$(doctor_line "$out" right-click)" "ok    right-click    5 entries"
}

test_doctor_does_not_warn_about_a_preset_taken_out_of_the_menu() {
  local box out
  box="$(installed_box)"
  HOME="$box/home" SHRINKIT_DIR="$box/work" zsh "$OPTIMIZER" preset remove 2x > /dev/null 2>&1

  out="$(run_doctor "$box" 2>&1)"

  check "counts the entries there are, and warns about none" contains "$(doctor_line "$out" right-click)" \
    "ok    right-click    4 entries"
}
