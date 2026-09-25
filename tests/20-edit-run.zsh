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

# The line of an edit file that reads exactly <text>, by its number.
line_of() {
  grep -n -x -F -- "$2" "$1" | head -1 | cut -d: -f1
}

test_run_skips_a_bad_line_and_says_which() {
  local box tools work file out before want n
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'top "speed = 3" "merge = yes"' \
    'add clip.mov "preset sharp" "sped = 3" "crf =" "crf = 90" "notify = true" "preset = shrp" "merge = true" "speed = 4"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"

  out="$(run_file "$box" "$tools" "$file")"
  before="${out%%\[1/1\]*}"

  for want in \
    "line $(line_of "$file" 'speed = 3'): only merge goes above the first recording" \
    "line $(line_of "$file" 'merge = yes'): merge = yes (want true or false)" \
    "line $(line_of "$file" 'preset sharp'): 'preset sharp' has no '='" \
    "line $(line_of "$file" 'sped = 3'): 'sped' is not a setting" \
    "line $(line_of "$file" 'crf ='): 'crf' has no value" \
    "line $(line_of "$file" 'crf = 90'): crf = 90 (want 0-51)" \
    "line $(line_of "$file" 'notify = true'): notify applies to the whole run; set it in settings.conf" \
    "line $(line_of "$file" 'preset = shrp'): no preset called 'shrp' (looked in $box/presets)" \
    "line $(line_of "$file" 'merge = true'): merge goes above the first recording"; do
    check "says $want" contains "$before" "  $want"$'\n'
    check "and logs it" logged "$box" "$want"
  done
  n="$(line_of "$file" 'speed = 4')"
  check "passes over a good line" lacks "$out" "line $n:"
  check "runs the block with what is left" duration_near "$work/clip.mp4" 3
  check "leaving merge off" contains "$out" "merge = false"
}

test_run_keeps_the_presets_value_when_a_line_is_refused() {
  local box tools work
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 28'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "preset = sharp" "crf = 90"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  run_file "$box" "$tools" "$work/clip.edit.txt" > /dev/null

  check "encodes at the preset's crf, not settings.conf's" logged "$box" 'encode clip.mov (.* crf18)'
  check "under the preset's name" exists "$work/clip-sharp.mp4"
}

test_run_leaves_out_a_recording_with_both_cut_and_keep() {
  local box tools work out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 a.mov" "cut = 3-4" "keep = 5-6"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-red.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"

  out="$(run_file "$box" "$tools" "$work/1 a.edit.txt")" || code=$?

  check "says why" contains "$out" \
    "[1/2] 1 a.mov: cut and keep are the same edit from opposite sides; this recording is left out"
  check "and logs it" logged "$box" "1 a.mov: cut and keep are the same edit from opposite sides"
  check "shrinks nothing for it" missing "$work/1 a.mp4"
  check "runs the next one" exists "$work/2 b.mp4"
  check "counts it as not shrunk" contains "$out" $'\nNot shrunk: 1 a.mov'
  check "and exits 1" test "$code" = 1
}

test_run_leaves_out_a_block_that_names_no_recording() {
  local box tools work out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor "print -r -- '' '[notes.txt]' >> \"\$file\""
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 gone.mov"
  print -r -- 'not a recording' > "$work/notes.txt"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 gone.mov"
  rm "$work/2 gone.mov"

  out="$(run_file "$box" "$tools" "$work/1 a.edit.txt" 2>&1)" || code=$?

  check "names the one that is gone" contains "$out" "[2/3] 2 gone.mov: not found beside 1 a.edit.txt"
  check "and the one that is no video" contains "$out" "[3/3] notes.txt is not a video (.mov, .mp4 or .m4v)"
  check "logs both" logged "$box" "2 gone.mov: not found beside 1 a.edit.txt"
  check "runs the one that is there" exists "$work/1 a.mp4"
  check "and nothing else" test "$(print -l "$work"/*.mp4(N) | wc -l | tr -d ' ')" = 1
  check "counts both as not shrunk" contains "$out" $'\nNot shrunk: 2 gone.mov, notes.txt'
  check "and exits 1" test "$code" = 1
}

test_run_refuses_a_file_saved_as_rich_text() {
  local box tools work out code=0
  local -a made
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  # textutil writes rich text with the Cocoa text system, as TextEdit does after Format > Make Rich
  # Text.
  stub_editor "$tools" editor 'add clip.mov "speed = 4"' \
    'textutil -convert rtf -output "$file.rtf" "$file" && mv "$file.rtf" "$file"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"

  out="$(run_edit "$box" "$tools" "$work/clip.mov")" || code=$?

  check "says what happened and how to fix it" contains "$out" \
    "clip.edit.txt was saved as rich text: in TextEdit, Format > Make Plain Text, save, and run it again"
  check "and logs it" logged "$box" "clip.edit.txt was saved as rich text"
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "and exits 1" test "$code" = 1
}

# The shape of a file TextEdit really saved (tasks: textedit-sample): a line typed in starts with a
# capital, a hyphen stays a hyphen, the range may be typed with spaces, and the last line typed has
# no line break after it.
test_run_reads_what_textedit_saves() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor \
    "printf '\\nPreset = sharp\\nCut = 0:03-0:04\\nSpeed = 2\\nCut = 0:08 - 0:09' >> \"\$file\""
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/1 intro.mov"
  make_edit "$box" "$tools" "$work/1 intro.mov"

  out="$(run_file "$box" "$tools" "$work/1 intro.edit.txt")"

  check "the file ends without a line break, as TextEdit left it" \
    test "$(tail -c 4 "$work/1 intro.edit.txt")" = '0:09'
  check "says nothing is wrong with a line" lacks "$out" "line "
  check "reads the capitalised preset" exists "$work/1 intro-sharp.mp4"
  check "and both cuts, the last line too, at the capitalised speed" \
    duration_near "$work/1 intro-sharp.mp4" 5
  check "so neither marker survives" no_marker_color_anywhere "$work/1 intro-sharp.mp4" 5
}

# TextEdit writes neither (tasks: textedit-sample), other editors do; the reading rules are
# read_settings' own.
test_run_reads_a_byte_order_mark_and_crlf_line_ends() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "speed = 4"' \
    "{ printf '\\xef\\xbb\\xbf'; awk '{ printf \"%s\\r\\n\", \$0 }' \"\$file\"; } > \"\$file.new\" && mv \"\$file.new\" \"\$file\""
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  out="$(run_file "$box" "$tools" "$work/clip.edit.txt")"

  check "the file starts with the mark" test "$(head -c 3 "$work/clip.edit.txt" | xxd -p)" = efbbbf
  check "and ends its lines with CR LF" test "$(tail -c 2 "$work/clip.edit.txt" | xxd -p)" = 0d0a
  check "says nothing is wrong with a line" lacks "$out" "line "
  check "finds the recording" exists "$work/clip.mp4"
  check "and reads its setting" duration_near "$work/clip.mp4" 3
}

# TextEdit's Smart Dashes can turn a typed '-' into an en dash or an em dash.
test_run_takes_a_smart_dash_between_two_times() {
  local box tools work en=$'\xe2\x80\x93' em=$'\xe2\x80\x94'
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor "add clip.mov 'cut = 3${en}4' 'cut = 8 ${em} 9'"
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  run_file "$box" "$tools" "$work/clip.edit.txt" > /dev/null

  check "an en dash and an em dash in the edit file" duration_near "$work/clip.mp4" 10
  check "cut what they name" no_marker_color_anywhere "$work/clip.mp4" 10

  cp "$FIXTURES/colored.mov" "$work/flag.mov"
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut "3${en}4" "$work/flag.mov" 2> /dev/null
  check "and in --cut" duration_near "$work/flag.mp4" 11
}

test_run_with_no_block_runs_nothing() {
  local box tools work out code=0
  local -a made
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  # How shrinkit edit is cancelled once the editor is open.
  stub_editor "$tools" editor 'drop_blocks'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"

  out="$(run_edit "$box" "$tools" "$work/clip.mov")" || code=$?

  check "says so" test "$out" = "No recording in clip.edit.txt, nothing to run."
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "and exits 1" test "$code" = 1
}
