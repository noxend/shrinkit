# Sourced by tests/run-tests.sh: shrinkit run, each block of an edit file with its own settings.

test_run_shrinks_each_recording_with_its_own_settings() {
  local box tools work code=0
  local -a files
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  mkdir -p "$box/presets"
  print -r -- 'speed = 4' > "$box/presets/fast.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 a.mov" "preset = fast"' \
    'add "2 b.mov" "speed = 3" "max_height = 720"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/1 a.mov"
  cp "$FIXTURES/withaudio.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"

  run_file "$box" "$tools" "$work/1 a.edit.txt" > /dev/null || code=$?

  check "the first is named after its preset" exists "$work/1 a-fast.mp4"
  check "and made at the preset's speed, not settings.conf's" duration_near "$work/1 a-fast.mp4" 3
  check "at its own height" test "$(height_of "$work/1 a-fast.mp4")" = 1080
  check "the second at its own speed" duration_near "$work/2 b.mp4" 4
  check "and its own height" test "$(height_of "$work/2 b.mp4")" = 720
  check "the recordings left in place" exists "$work/1 a.mov"
  files=("$work"/*(N))
  check "and nothing else made beside them" test "${#files}" = 5
  check "exits 0" test "$code" = 0
}

test_run_cuts_and_keeps_per_recording() {
  local box tools work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 cut.mov" "cut = 3-4" "cut = 8-9"' 'add "2 keep.mov" "keep = 3-4"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/1 cut.mov"
  cp "$FIXTURES/colored.mov" "$work/2 keep.mov"
  make_edit "$box" "$tools" "$work/1 cut.mov" "$work/2 keep.mov"

  run_file "$box" "$tools" "$work/1 cut.edit.txt" > /dev/null

  check "the first loses both of its ranges" duration_near "$work/1 cut.mp4" 10
  check "and no red or green frame survives in it" no_marker_color_anywhere "$work/1 cut.mp4" 10
  check "the second keeps only its range" duration_near "$work/2 keep.mp4" 1
  check "and it is the red second" color_at_is 0.5 "$work/2 keep.mp4" fe0000
}

# TextEdit capitalises the first letter of a line, and settings.conf spells keys with '_' where a
# flag has '-'.
test_run_reads_keys_whatever_their_case() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'remove_audio = true'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor \
    'add clip.mov "Preset = sharp" "CUT = 3-4" "Max-Height = 180" "Remove-Audio = FALSE" "Codec = HEVC"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  run_file "$box" "$tools" "$work/clip.edit.txt" > /dev/null
  out="$work/clip-sharp.mp4"

  check "Preset" exists "$out"
  check "CUT" duration_near "$out" 11
  check "Max-Height" test "$(height_of "$out")" = 180
  check "Remove-Audio = FALSE" has_audio "$out"
  check "Codec = HEVC" test "$(video_codec "$out")" = hevc
}

test_run_settings_of_one_block_do_not_reach_the_next() {
  local box tools work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  mkdir -p "$box/presets"
  print -rl -- 'crf = 32' 'max_height = 1080' > "$box/presets/tiny.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 big.mov" "preset = tiny" "cut = 1-2" "codec = hevc"'
  work="$(scratch)"
  cp "$FIXTURES/tall.mov" "$work/1 big.mov"
  cp "$FIXTURES/tall.mov" "$work/2 big.mov"
  make_edit "$box" "$tools" "$work/1 big.mov" "$work/2 big.mov"

  run_file "$box" "$tools" "$work/1 big.edit.txt" > /dev/null

  check "the first block gets its preset's height" test "$(height_of "$work/1 big-tiny.mp4")" = 1080
  check "the second is named without it" exists "$work/2 big.mp4"
  check "and keeps its own height" test "$(height_of "$work/2 big.mp4")" = 2160
  check "and its whole length" duration_near "$work/2 big.mp4" 5
  check "and settings.conf's codec" test "$(video_codec "$work/2 big.mp4")" = h264
}

test_run_shows_the_log_on_the_terminal_but_not_the_graph() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "cut = 3-4" "speed = 2"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  out="$(run_file "$box" "$tools" "$work/clip.edit.txt")"

  check "says what it runs" contains "$out" "Running clip.edit.txt: 1 recording, merge = false"
  check "heads the block with its settings" contains "$out" $'\n[1/1] clip.mov   cut 3-4, speed 2\n'
  check "shows the encode line under it" contains "$out" $'\n  encode clip.mov (360p, 2x, '
  check "and the done line" contains "$out" $'\n  done   clip.mp4 ('
  check "without the dates the log has" lacks "$out" "$(date +%Y-)"
  check "and without the filter graph" lacks "$out" "graph"
  check "which stays in the log" logged "$box" 'graph  clip.mov'
  check "ends by naming what came out" contains "$out" $'\nDone.\n  '"$work/clip.mp4  ("
}

test_run_names_the_block_a_bad_range_came_from() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "cut = 3x-4"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  out="$(run_file "$box" "$tools" "$work/clip.edit.txt")"

  check "in the log" logged "$box" "ignoring cut '3x-4' in the block for clip.mov (want start-end, end after start)"
  check "and on the terminal" contains "$out" "  ignoring cut '3x-4' in the block for clip.mov"
}

test_run_goes_on_past_a_recording_it_cannot_shrink() {
  local box tools work out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  print -r -- 'not a movie' > "$work/1 broken.mov"
  cp "$FIXTURES/take-red.mov" "$work/2 fine.mov"
  make_edit "$box" "$tools" "$work/1 broken.mov" "$work/2 fine.mov"

  out="$(run_file "$box" "$tools" "$work/1 broken.edit.txt" 2> /dev/null)" || code=$?

  check "shrinks the one after it" exists "$work/2 fine.mp4"
  check "names the one it could not shrink" contains "$out" $'\nNot shrunk: 1 broken.mov'
  check "and exits 1" test "$code" = 1
}

test_edit_runs_the_file_once_the_editor_closes() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "speed = 4"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  out="$(run_edit "$box" "$tools" "$work/clip.mov")"

  check "runs what was saved" duration_near "$work/clip.mp4" 3
  check "and says so" contains "$out" "Running clip.edit.txt: 1 recording"
}

test_run_without_a_file_is_refused() {
  local box tools out code=0
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"

  out="$(run_file "$box" "$tools" 2>&1)" || code=$?
  check "named nothing, exits 2" test "$code" = 2
  check "and says what it wants" contains "$out" "run needs one edit file"

  code=0
  out="$(run_file "$box" "$tools" "$box/nothing.edit.txt" 2>&1)" || code=$?
  check "a file that is not there, exits 2" test "$code" = 2
  check "and names it" contains "$out" "cannot read $box/nothing.edit.txt"
}
