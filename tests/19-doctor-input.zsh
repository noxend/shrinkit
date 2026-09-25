# Sourced by tests/run-tests.sh: doctor's check of what is waiting in input/.

test_doctor_counts_what_is_waiting_and_ignores_what_finder_leaves() {
  local box out
  box="$(installed_box)"
  : > "$box/work/input/.DS_Store"  # written by Finder whenever the folder is opened
  : > "$box/work/input/._clip.mov" # its metadata beside a file on a non-Apple drive
  cp "$FIXTURES/silent.mov" "$box/work/input/clip.mov"

  out="$(run_doctor "$box" 2>&1)"

  check "counts the recording, not what is beside it" \
    test "$(doctor_line "$out" input)" = "ok    input          1 waiting: clip.mov"
}

test_doctor_warns_about_what_the_watcher_never_picks_up() {
  local box out code=0
  box="$(installed_box)"
  cp "$FIXTURES/silent.mov" "$box/work/input/clip.mkv"
  mkdir -p "$box/work/input/day one"
  cp "$FIXTURES/silent.mov" "$box/work/input/.clip.mov"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "warns, listing each" test "$(doctor_line "$out" input)" = \
    "warn  input          never picked up: .clip.mov, clip.mkv, day one/"
  check "and exits 0" test "$code" = 0
}

test_doctor_warns_about_a_recording_that_failed_and_not_a_new_copy() {
  local box out copied
  box="$(installed_box)"
  print -r -- "this is not really a video" > "$box/work/input/clip.mov"
  run_agent "$box"

  out="$(run_doctor "$box" 2>&1)"
  rm "$box/work/input/clip.mov"
  cp "$FIXTURES/silent.mov" "$box/work/input/clip.mov" # the good one, under the same name
  copied="$(run_doctor "$box" 2>&1)"

  check "warns that it could not be shrunk" \
    contains "$(doctor_line "$out" input)" "clip.mov could not be shrunk"
  check "and where the reason is" contains "$(doctor_block "$out" input)" "$box/work/.logs/optimizer.log"
  check "but finds the new copy waiting" \
    test "$(doctor_line "$copied" input)" = "ok    input          1 waiting: clip.mov"
}

test_doctor_warns_about_a_recording_shrunk_but_not_filed_away() {
  local box out
  box="$(installed_box)"
  cp "$FIXTURES/silent.mov" "$box/work/input/clip.mov"
  chmod a-w "$box/work/.processed" # the original cannot be moved out of input/
  run_agent "$box"
  chmod u+w "$box/work/.processed"

  out="$(run_doctor "$box" 2>&1)"

  check "the run did make the result" exists "$box/work/output/clip.mp4"
  check "warns that it could not be moved" test "$(doctor_line "$out" input)" = \
    "warn  input          clip.mov was shrunk, but could not be moved out of input/"
}

test_doctor_warns_when_it_cannot_look_inside_input() {
  local box out
  box="$(installed_box)"
  chmod 000 "$box/work/input"

  out="$(run_doctor "$box" 2>&1)"
  chmod 755 "$box/work/input"

  check "warns rather than finding nothing" \
    test "$(doctor_line "$out" input)" = "warn  input          cannot look inside $box/work/input"
}

test_doctor_prints_no_control_character_from_a_name() {
  local box fine out
  box="$(installed_box)"
  # Names that would move the cursor and wipe a line, the way a line can be faked on screen: one
  # doctor lists on an ok line, and one it warns about.
  cp "$FIXTURES/silent.mov" "$box/work/input/clip"$'\e[2K'".mov"
  cp "$box/work/presets/2x.conf" "$box/work/presets/p"$'\e[31m'"red.conf"
  fine="$(run_doctor "$box" 2>&1)"
  : > "$box/work/input/clip"$'\e[2K'".mkv"

  out="$(run_doctor "$box" 2>&1)"

  check "shows the recording with a ? instead" contains "$(doctor_line "$fine" input)" "clip?[2K.mov"
  check "and the preset" contains "$(doctor_line "$fine" presets)" "p?[31mred"
  check "and the file it warns about" contains "$(doctor_line "$out" input)" "clip?[2K.mkv"
  check "and prints no escape" test -z "$(print -r -- "$fine$out" | tr -d -c '\033')"
}

test_doctor_warns_when_there_is_no_input_folder() {
  local box out
  box="$(installed_box)"
  rm -rf "$box/work/input"

  out="$(run_doctor "$box" 2>&1)"

  check "warns" test "$(doctor_line "$out" input)" = "warn  input          there is no $box/work/input"
  check "and says how to make it again" contains "$(doctor_block "$out" input)" "  shrinkit setup"
}
