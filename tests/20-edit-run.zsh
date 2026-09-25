# Sourced by tests/run-tests.sh: shrinkit run, each block of an edit file with its own settings.

# The runner puts these first on the PATH, as it points launchctl at a refusal: a test that forgot
# its own stub would otherwise open windows or post banners on the Mac running it.
test_open_and_osascript_without_a_stub_are_refused() {
  local out code
  code=0
  out="$(open -R /nonexistent/shrinkit-refusal-probe 2>&1)" || code=$?
  check "open is refused" test "$code" = 99
  check "and says why" contains "$out" "a test reached open without its stub"
  code=0
  out="$(osascript -e 'return 0' 2>&1)" || code=$?
  check "osascript is refused" test "$code" = 99
  check "and says why" contains "$out" "a test reached osascript without its stub"
  # notify throws away all osascript says, so the refusal is written down for the runner to see.
  osascript -l JavaScript - banner > /dev/null 2>&1 < /dev/null || true
  check "a call whose output is thrown away is still caught" \
    grep -q '^osascript -l JavaScript - banner$' "$TMPROOT/refused"
  : > "$TMPROOT/refused"
}

test_run_shrinks_each_recording_with_its_own_settings() {
  local box tools work file code=0
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
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"

  run_file "$box" "$tools" "$file" > /dev/null || code=$?

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
  local box tools work file
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 cut.mov" "cut = 3-4" "cut = 8-9"' 'add "2 keep.mov" "keep = 3-4"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/1 cut.mov"
  cp "$FIXTURES/colored.mov" "$work/2 keep.mov"
  file="$(make_edit "$box" "$tools" "$work/1 cut.mov" "$work/2 keep.mov")"

  run_file "$box" "$tools" "$file" > /dev/null

  check "the first loses both of its ranges" duration_near "$work/1 cut.mp4" 10
  check "and no red or green frame survives in it" no_marker_color_anywhere "$work/1 cut.mp4" 10
  check "the second keeps only its range" duration_near "$work/2 keep.mp4" 1
  check "and it is the red second" color_at_is 0.5 "$work/2 keep.mp4" fe0000
}

# TextEdit capitalises the first letter of a line, and settings.conf spells keys with '_' where a
# flag has '-'.
test_run_reads_keys_whatever_their_case() {
  local box tools work file out
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
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  run_file "$box" "$tools" "$file" > /dev/null
  out="$work/clip-sharp.mp4"

  check "Preset" exists "$out"
  check "CUT" duration_near "$out" 11
  check "Max-Height" test "$(height_of "$out")" = 180
  check "Remove-Audio = FALSE" has_audio "$out"
  check "Codec = HEVC" test "$(video_codec "$out")" = hevc
}

test_run_settings_of_one_block_do_not_reach_the_next() {
  local box tools work file
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
  file="$(make_edit "$box" "$tools" "$work/1 big.mov" "$work/2 big.mov")"

  run_file "$box" "$tools" "$file" > /dev/null

  check "the first block gets its preset's height" test "$(height_of "$work/1 big-tiny.mp4")" = 1080
  check "the second is named without it" exists "$work/2 big.mp4"
  check "and keeps its own height" test "$(height_of "$work/2 big.mp4")" = 2160
  check "and its whole length" duration_near "$work/2 big.mp4" 5
  check "and settings.conf's codec" test "$(video_codec "$work/2 big.mp4")" = h264
}

test_run_shows_the_log_on_the_terminal_but_not_the_graph() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "cut = 3-4" "speed = 2"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  out="$(run_file "$box" "$tools" "$file")"

  check "says what it runs" test "${${(@f)out}[1]}" = "shrinkit run  ${file:t}"
  check "and what is in it" test "${${(@f)out}[2]}" = "1 recording, merge = false"
  check "heads the block with its settings" contains "$out" $'\n[1/1] clip.mov\n      cut 3-4, speed 2\n'
  check "shows the encode under it" contains "$out" $'\n      encoding  clip.mov (360p, 2x, '
  check "on a line of its own, not a bar, since this is not a terminal" lacks "$out" $'\r'
  check "and what came of it" contains "$out" $'\n      done      clip.mp4 ('
  check "without the dates the log has" lacks "$out" "$(date +%Y-)"
  check "and without the filter graph" lacks "$out" "graph"
  check "which stays in the log" logged "$box" 'graph  clip.mov'
  check "ends with what came out, its size and how long it plays" contains "$out" \
    $'\nDone  '"$(du -h "$work/clip.mp4" | cut -f1 | tr -d ' ')  $(printf '%.1fs' "$(duration "$work/clip.mp4")")"$'\n'
  check "and where it is" test "${${(@f)out}[-1]}" = "      $work/clip.mp4"
}

test_run_names_the_block_a_bad_range_came_from() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "cut = 3x-4"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  out="$(run_file "$box" "$tools" "$file")"

  check "in the log" logged "$box" "ignoring cut '3x-4' in the block for clip.mov (want start-end, end after start)"
  check "and on the terminal, as skipped" contains "$out" "      skipped   cut '3x-4' in the block for clip.mov"
}

# On the terminal a step goes under a word for what it says; the log keeps its own words, for
# reading back and for doctor.
test_run_says_each_step_under_its_word_and_keeps_the_log_plain() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 a.mov" "sped = 3" "cut = 3x-4"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  print -r -- 'not a movie' > "$work/2 broken.mov"
  cp "$FIXTURES/take-blue.mov" "$work/3 gone.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 broken.mov" "$work/3 gone.mov")"
  rm "$work/3 gone.mov"

  out="$(run_file "$box" "$tools" "$file" 2> /dev/null)"

  check "a line that cannot be used is skipped" contains "$out" $'\n      skipped   line '
  check "and so is a block that cannot" contains "$out" $'\n      skipped   [3/3] 3 gone.mov: not found beside'
  check "and a range" contains "$out" $'\n      skipped   cut \'3x-4\''
  check "a block's header" contains "$out" $'\n[1/3] 1 a.mov\n'
  check "an encode" contains "$out" $'\n      encoding  1 a.mov ('
  check "a result" contains "$out" $'\n      done      1 a.mp4 ('
  check "a failure" contains "$out" $'\n      failed    '"$work/2 broken.mov"
  check "and the run's" contains "$out" $'\nNot every recording was shrunk.\n'
  check "the log keeps its words" logged "$box" '  line [0-9]*: .sped. is not a setting$'
  check "an encode's" logged "$box" '  encode 1 a.mov ('
  check "a result's" logged "$box" '  done   1 a.mp4 ('
  check "a failure's" logged "$box" "  FAILED $work/2 broken.mov"
  check "and a range's" logged "$box" "  ignoring cut '3x-4'"
  check "and none of the screen's" not_logged "$box" '      \(skipped\|encoding\|done\|failed\)  '
}

test_run_goes_on_past_a_recording_it_cannot_shrink() {
  local box tools work file out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  print -r -- 'not a movie' > "$work/1 broken.mov"
  cp "$FIXTURES/take-red.mov" "$work/2 fine.mov"
  file="$(make_edit "$box" "$tools" "$work/1 broken.mov" "$work/2 fine.mov")"

  out="$(run_file "$box" "$tools" "$file" 2> /dev/null)" || code=$?

  check "shrinks the one after it" exists "$work/2 fine.mp4"
  check "names the one it could not shrink" contains "$out" $'\n      Not shrunk: 1 broken.mov'
  check "and exits 1" test "$code" = 1
  check "sends the terminal to the log for what ffmpeg said" contains "$out" \
    "      failed    $work/1 broken.mov (one-shot, ffmpeg output is in $box/.logs/optimizer.log)"
  check "while the log keeps its own words" logged "$box" \
    "FAILED $work/1 broken.mov (one-shot, ffmpeg output is above)"
}

# settings.conf is read once for a run, so a value in it that does not fit is said once, with the
# lines of the edit file, not again for every block.
test_run_says_a_bad_value_in_settings_conf_once() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 90'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"

  out="$(run_file "$box" "$tools" "$file")"

  check "says it before the first recording" contains "${out%%\[1/2\]*}" \
    "      skipped   crf='90' (want 0-51), using '28'"$'\n'
  check "once on the terminal" test "$(grep -c "crf='90'" <<< "$out")" = 1
  check "and once in the log" test "$(log_count "$box" "ignoring crf=")" = 1
  check "and encodes both at the default" test "$(log_count "$box" 'encode .* crf28)')" = 2
}

# A line of settings.conf the run cannot read is said with the lines of the edit file too, not only
# written to the log.
test_run_says_a_line_of_settings_conf_it_cannot_read() {
  local box tools work file out before
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf 30' 'sped = 3'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  out="$(run_file "$box" "$tools" "$file")"
  before="${out%%\[1/1\]*}"

  check "says a line with no '=' under the lines that head the run" test "${${(@f)out}[4]}" = \
    "      skipped   settings.conf line 3: 'crf 30' has no '='"
  check "and a key that is not a setting" contains "$before" \
    "      skipped   'sped' in settings.conf line 4: not a setting"$'\n'
  check "once each on the terminal" test "$(grep -c 'settings.conf line' <<< "$out")" = 2
  check "and once each in the log" test "$(log_count "$box" 'settings.conf line')" = 2
  check "with a blank line before the first recording" contains "$out" $'not a setting\n\n[1/1] clip.mov'
}

test_edit_runs_the_file_once_the_editor_closes() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "speed = 4"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  out="$(run_edit "$box" "$tools" "$work/clip.mov")"
  file="$(edited "$tools")"

  check "runs what was saved" duration_near "$work/clip.mp4" 3
  check "and says so" test "${${(@f)out}[1]}" = "shrinkit run  ${file:t}"
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
  stub_editor "$tools" editor 'top "speed = 3" "merge =" "merge = yes"' \
    'add clip.mov "preset sharp" "sped = 3" "crf =" "crf = 90" "notify = true" "preset = shrp" "merge = true" "speed = 4"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  out="$(run_file "$box" "$tools" "$file")"
  before="${out%%\[1/1\]*}"

  for want in \
    "line $(line_of "$file" 'speed = 3'): only merge goes above the first recording" \
    "line $(line_of "$file" 'merge ='): 'merge' has no value" \
    "line $(line_of "$file" 'merge = yes'): merge = yes (want true or false)" \
    "line $(line_of "$file" 'preset sharp'): 'preset sharp' has no '='" \
    "line $(line_of "$file" 'sped = 3'): 'sped' is not a setting" \
    "line $(line_of "$file" 'crf ='): 'crf' has no value" \
    "line $(line_of "$file" 'crf = 90'): crf = 90 (want 0-51)" \
    "line $(line_of "$file" 'notify = true'): notify applies to the whole run; set it in settings.conf" \
    "line $(line_of "$file" 'preset = shrp'): no preset called 'shrp' (looked in $box/presets)" \
    "line $(line_of "$file" 'merge = true'): merge goes above the first recording"; do
    check "says $want" contains "$before" "      skipped   $want"$'\n'
    check "and logs it" logged "$box" "$want"
  done
  n="$(line_of "$file" 'speed = 4')"
  check "passes over a good line" lacks "$out" "line $n:"
  check "runs the block with what is left" duration_near "$work/clip.mp4" 3
  check "leaving merge off" contains "$out" "merge = false"
}

test_run_keeps_the_presets_value_when_a_line_is_refused() {
  local box tools work file
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 28'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "preset = sharp" "crf = 90"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  run_file "$box" "$tools" "$file" > /dev/null

  check "encodes at the preset's crf, not settings.conf's" logged "$box" 'encode clip.mov (.* crf18)'
  check "under the preset's name" exists "$work/clip-sharp.mp4"
}

test_run_leaves_out_a_recording_with_both_cut_and_keep() {
  local box tools work file out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 a.mov" "cut = 3-4" "keep = 5-6"'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-red.mov" "$work/2 b.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"

  out="$(run_file "$box" "$tools" "$file")" || code=$?

  check "says why" contains "$out" \
    $'\n'"      skipped   [1/2] 1 a.mov: cut and keep are the same edit from opposite sides; this recording is left out"
  check "and logs it" logged "$box" "1 a.mov: cut and keep are the same edit from opposite sides"
  check "shrinks nothing for it" missing "$work/1 a.mp4"
  check "runs the next one" exists "$work/2 b.mp4"
  check "counts it as not shrunk" contains "$out" $'\n      Not shrunk: 1 a.mov'
  check "and exits 1" test "$code" = 1
}

test_run_leaves_out_a_block_that_names_no_recording() {
  local box tools work file out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor "print -r -- '' '[notes.txt]' >> \"\$file\""
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 gone.mov"
  print -r -- 'not a recording' > "$work/notes.txt"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 gone.mov")"
  rm "$work/2 gone.mov"

  out="$(run_file "$box" "$tools" "$file" 2>&1)" || code=$?

  check "names the one that is gone" contains "$out" $'\n'"      skipped   [2/3] 2 gone.mov: not found beside ${file:t}"
  check "and the one that is no video" contains "$out" $'\n'"      skipped   [3/3] notes.txt is not a video (.mov, .mp4 or .m4v)"
  check "logs both" logged "$box" "2 gone.mov: not found beside ${file:t}"
  check "runs the one that is there" exists "$work/1 a.mp4"
  check "and nothing else" test "$(print -l "$work"/*.mp4(N) | wc -l | tr -d ' ')" = 1
  check "counts both as not shrunk" contains "$out" $'\n      Not shrunk: 2 gone.mov, notes.txt'
  check "and exits 1" test "$code" = 1
}

test_run_refuses_a_file_saved_as_rich_text() {
  local box tools work file out code=0
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
  file="$(edited "$tools")"

  check "says what happened and how to fix it, and nothing else" test "$out" = \
    "${file:t} was saved as rich text: in TextEdit, Format > Make Plain Text, save, and run it again"
  check "and logs it" logged "$box" "${file:t} was saved as rich text"
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "and exits 1" test "$code" = 1
}

# The shape of a file TextEdit really saved (tasks: textedit-sample): a line typed in starts with a
# capital, a hyphen stays a hyphen, the range may be typed with spaces, and the last line typed has
# no line break after it.
test_run_reads_what_textedit_saves() {
  local box tools work file out
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
  file="$(make_edit "$box" "$tools" "$work/1 intro.mov")"

  out="$(run_file "$box" "$tools" "$file")"

  check "the file ends without a line break, as TextEdit left it" \
    test "$(tail -c 4 "$file")" = '0:09'
  check "says nothing is wrong with a line" lacks "$out" "line "
  check "reads the capitalised preset" exists "$work/1 intro-sharp.mp4"
  check "and both cuts, the last line too, at the capitalised speed" \
    duration_near "$work/1 intro-sharp.mp4" 5
  check "so neither marker survives" no_marker_color_anywhere "$work/1 intro-sharp.mp4" 5
}

# TextEdit writes neither (tasks: textedit-sample), other editors do; the reading rules are
# read_settings' own.
test_run_reads_a_byte_order_mark_and_crlf_line_ends() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "speed = 4"' \
    "{ printf '\\xef\\xbb\\xbf'; awk '{ printf \"%s\\r\\n\", \$0 }' \"\$file\"; } > \"\$file.new\" && mv \"\$file.new\" \"\$file\""
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  out="$(run_file "$box" "$tools" "$file")"

  check "the file starts with the mark" test "$(head -c 3 "$file" | xxd -p)" = efbbbf
  check "and ends its lines with CR LF" test "$(tail -c 2 "$file" | xxd -p)" = 0d0a
  check "says nothing is wrong with a line" lacks "$out" "line "
  check "finds the recording" exists "$work/clip.mp4"
  check "and reads its setting" duration_near "$work/clip.mp4" 3
}

# TextEdit's Smart Dashes can turn a typed '-' into an en dash or an em dash.
test_run_takes_a_smart_dash_between_two_times() {
  local box tools work file en=$'\xe2\x80\x93' em=$'\xe2\x80\x94'
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor "add clip.mov 'cut = 3${en}4' 'cut = 8 ${em} 9'"
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  run_file "$box" "$tools" "$file" > /dev/null

  check "an en dash and an em dash in the edit file" duration_near "$work/clip.mp4" 10
  check "cut what they name" no_marker_color_anywhere "$work/clip.mp4" 10

  cp "$FIXTURES/colored.mov" "$work/flag.mov"
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut "3${en}4" "$work/flag.mov" 2> /dev/null
  check "and in --cut" duration_near "$work/flag.mp4" 11
}

test_run_with_no_block_runs_nothing() {
  local box tools work file out code=0
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
  file="$(edited "$tools")"

  check "says so" test "$out" = "No recording in ${file:t}, nothing to run."
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "and exits 1" test "$code" = 1
}

test_run_posts_one_banner_at_the_end() {
  local box tools work file out
  local -a banners
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify = true' 'notify_start = true' 'notify_sound = Ping'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  cp "$FIXTURES/take-green.mov" "$work/3 c.mov"
  # A sidecar left from 3.x, which a one-shot run names in a banner of its own.
  print -r -- '0-1' > "$work/2 b.mov.cuts"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov" "$work/3 c.mov")"
  rm "$work/3 c.mov"

  out="$(run_file "$box" "$tools" "$file")"
  banners=(${(f)"$(grep '^banner ' "$tools/osascript.log")"})

  check "one banner for the whole run" test "${#banners}" = 1
  check "saying what came out and what did not" contains "${banners[1]-}" \
    "2 of 3 shrunk: 1 a.mp4, 2 b.mp4. Not shrunk: 3 c.mov"
  check "with the sound settings.conf names" test "${${banners[1]-}##* | }" = Ping
  check "a leftover .cuts is still said on the terminal" contains "$out" "      note      2 b.mov.cuts is no longer read"

  print -r -- 'notify = false' >> "$box/settings.conf"
  : > "$tools/osascript.log"
  run_file "$box" "$tools" "$file" > /dev/null
  check "and with notify = false, none" test "$(grep -c '^banner ' "$tools/osascript.log")" = 0
}

test_run_puts_every_result_on_the_clipboard() {
  local box tools work file out
  local -a copies
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'copy_to_clipboard = true'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"

  out="$(run_file "$box" "$tools" "$file")"
  copies=(${(f)"$(grep '^clipboard ' "$tools/osascript.log")"})

  check "one copy for the whole run" test "${#copies}" = 1
  check "holding every result" test "${copies[1]-}" = "clipboard $work/1 a.mp4 | $work/2 b.mp4"
  check "no recording claims a copy of its own" not_logged "$box" 'done .*copied to clipboard'
  check "and the terminal says so under them" test "${${(@f)out}[-1]}" = "      copied to the clipboard"
}
