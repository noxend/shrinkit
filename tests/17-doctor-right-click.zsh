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
  rm -rf "$box/home/Library/Services/shrinkit: merge.workflow"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "warns about the preset with no entry" \
    contains "$(doctor_block "$out" right-click)" "no right-click entry for the preset quick one"
  check "saying how to add it, quoted to paste" \
    contains "$(doctor_block "$out" right-click)" "  shrinkit preset install 'quick one'"
  check "and about the entry that went" contains "$(doctor_block "$out" right-click)" "no right-click entry for merge"
  check "and exits 0" test "$code" = 0
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

test_doctor_says_setup_brings_back_an_entry_taken_out() {
  local box out
  box="$(installed_box)"
  HOME="$box/home" SHRINKIT_DIR="$box/work" zsh "$OPTIMIZER" preset remove 2x > /dev/null 2>&1

  out="$(run_doctor "$box" 2>&1)"
  run_setup "$box" > /dev/null 2>&1

  check "warns that the preset has no entry" \
    contains "$(doctor_block "$out" right-click)" "no right-click entry for the preset 2x"
  check "and says how to keep it out" \
    contains "$(doctor_block "$out" right-click)" "move the preset file out of presets/"
  check "which is right: the next setup builds it again" \
    test -d "$box/home/Library/Services/shrinkit: 2x.workflow"
}
