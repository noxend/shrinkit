# Sourced by tests/run-tests.sh: doctor's check of settings.conf and the presets.

test_doctor_warns_about_the_settings_a_run_leaves_out() {
  local box out code=0
  box="$(installed_box)"
  print -rl -- 'crf: 40' 'output_suffix = -2x' 'fps = 999' >> "$box/work/settings.conf"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  # In the words a run logs them with, since that is what doctor reads.
  check "warns about the line without =" \
    contains "$(doctor_block "$out" settings)" "ignoring settings.conf line $(grep -n 'crf: 40' "$box/work/settings.conf" | cut -d: -f1): 'crf: 40' has no '='"
  check "about the key that is not a setting" \
    contains "$(doctor_block "$out" settings)" "ignoring 'output_suffix' in settings.conf"
  check "and about the value out of range" \
    contains "$(doctor_block "$out" settings)" "ignoring fps='999' (want 0-240), in settings.conf"
  check "and exits 0, since a run goes on without them" test "$code" = 0
}

test_doctor_reads_the_presets_the_same_way() {
  local box out
  box="$(installed_box)"
  print -r -- 'speed 3' >> "$box/work/presets/tiny.conf"

  out="$(run_doctor "$box" 2>&1)"

  check "warns about the preset" contains "$(doctor_line "$out" presets)" "warn  presets        ignoring tiny.conf line"
  check "and leaves the settings alone" verdict_is "$out" settings ok
}

test_doctor_warns_about_settings_it_cannot_read() {
  local box out
  box="$(installed_box)"
  chmod 000 "$box/work/settings.conf"

  out="$(run_doctor "$box" 2>&1)"
  chmod 644 "$box/work/settings.conf"

  check "warns that a run uses none of it" \
    test "$(doctor_line "$out" settings)" = "warn  settings       cannot read $box/work/settings.conf, so a run uses none of it"
}
