# Sourced by tests/run-tests.sh: an edit run's screen on a terminal of its own, where it is drawn in
# colour; everywhere else the tests read the same words without it.

# The escape character every colour code starts with.
ESC=$'\e'

test_run_on_a_terminal_says_each_word_in_its_colour() {
  local box tools work file screen
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add "1 a.mov" "sped = 3"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  print -r -- 'not a movie' > "$work/2 broken.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 broken.mov")"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(tr -d '\r' < "$tools/screen")"

  check "the run in bold, then its file" contains "$screen" "${ESC}[1mshrinkit run${ESC}[0m  ${file:t}"$'\n'
  check "what is in it dim" contains "$screen" $'\n'"${ESC}[2m2 recordings, merge = false${ESC}[0m"$'\n'
  check "a line skipped in yellow" contains "$screen" $'\n'"      ${ESC}[33mskipped  ${ESC}[0m line "
  check "a block's number in bold" contains "$screen" $'\n'"${ESC}[1m[1/2]${ESC}[0m 1 a.mov"$'\n'
  check "its settings dim" contains "$screen" $'\n'"      ${ESC}[2msettings.conf as it is${ESC}[0m"$'\n'
  check "an encode in cyan" contains "$screen" "      ${ESC}[36mencoding ${ESC}[0m"
  check "a result in green, by its sizes" contains "$screen" \
    "      ${ESC}[32mdone     ${ESC}[0m $(size_of "$work/1 a.mov") -> $(size_of "$work/1 a.mp4")"$'\n'
  check "a failure in red" contains "$screen" "      ${ESC}[31mfailed   ${ESC}[0m $work/2 broken.mov"
  check "and a run that did not go through in bold red" contains "$screen" \
    $'\n'"${ESC}[31m${ESC}[1mNot every recording was shrunk.${ESC}[0m"$'\n'
  check "while the log has no colour" not_logged "$box" "$ESC"
}

test_run_merge_on_a_terminal_says_the_join_and_the_result_in_colour() {
  local box tools work file screen out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'copy_to_clipboard = true'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"
  out="${file%.edit.txt}-merged.mp4"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(tr -d '\r' < "$tools/screen")"

  check "the join headed in bold" contains "$screen" $'\n'"${ESC}[1m[join]${ESC}[0m 2 parts"$'\n'
  check "and joined in magenta" contains "$screen" \
    "      ${ESC}[35mjoined   ${ESC}[0m 2 clips into ${out:t} (streams copied)"
  check "Done in bold green, the size in bold, how long it plays dim" contains "$screen" \
    $'\n'"${ESC}[32m${ESC}[1mDone${ESC}[0m  ${ESC}[1m$(du -h "$out" | cut -f1 | tr -d ' ')${ESC}[0m  ${ESC}[2m$(printf '%.1fs' "$(duration "$out")")${ESC}[0m"$'\n'
  check "then the file, its folder dim" contains "$screen" $'\n'"      ${ESC}[2m$work/${ESC}[0m${out:t}"$'\n'
  check "and what else happened dim" contains "$screen" $'\n'"      ${ESC}[2mcopied to the clipboard${ESC}[0m"
}

# no-color.org: NO_COLOR set to anything turns colour off, and the bar with it.
test_run_on_a_terminal_with_no_color_set_says_the_words_alone() {
  local box tools work file screen
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  in_terminal "$tools" env NO_COLOR=1 PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(tr -d '\r' < "$tools/screen")"

  check "runs the file" exists "$work/clip.mp4"
  check "with no escape code on the screen" lacks "$(< "$tools/screen")" "$ESC"
  check "an encode on a line of its own" contains "$screen" $'\n      encoding  clip.mov ('
  check "and what came of it" contains "$screen" \
    $'\n      done      '"$(size_of "$work/clip.mov") -> $(size_of "$work/clip.mp4")"$'\n'
}

# The frames an in_terminal screen drew for one step, the step's word first in its colour: each
# redraw goes back to the start of the line with a carriage return and writes the whole line again.
drawn_frames() {
  local screen="$1" word="$2" frame
  for frame in "${(@ps:\r:)screen}"; do
    [[ "$frame" == "      ${ESC}[3"[0-7]"m$word "* ]] && print -r -- "$frame"
  done
}

# Without its escape codes.
plain() {
  sed -E $'s/\e\\[[0-9;?]*[A-Za-z]//g'
}

# A bar of 30 cells, written out whole, so a test compares it byte by byte in any locale.
BAR30=""
for _cell in {1..30}; do BAR30="$BAR30━"; done
unset _cell

# 20 seconds of 4K kept at speed 2: a result 10 seconds long, and an encode of a second or more.
test_run_on_a_terminal_draws_an_encode_as_a_bar_redrawn_in_place() {
  local box tools work file screen after frame rest left=0
  local -a frames plain_frames percents
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "keep = 0:05-0:25"'
  work="$(scratch)"
  cp "$FIXTURES/big.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(< "$tools/screen")"
  frames=(${(f)"$(drawn_frames "$screen" encoding)"})
  plain_frames=(${(f)"$(print -rl -- "${frames[@]}" | plain)"})
  for frame in "${plain_frames[@]}"; do
    [[ "$frame" == "      encoding  $BAR30 "* ]] || continue
    rest="${frame#"      encoding  $BAR30 "}"
    percents+=("${${rest##[[:space:]]#}%%\%*}")
    [[ "$rest" == *%\ \ [0-9]*s\ left ]] && ((++left))
  done

  check "draws the encode as a bar" test "${#frames}" -ge 1
  check "redrawn in place, from the start of its line" test "${#frames}" -ge 2
  check "30 cells, then the percent" test "${#percents}" = "${#frames}"
  check "in place of the encode's line" lacks "$screen" "${ESC}[36mencoding ${ESC}[0m clip.mov ("
  check "the part done in cyan" contains "${(F)frames}" "      ${ESC}[36mencoding ${ESC}[0m ${ESC}[36m━"
  check "and the rest dim" contains "${(F)frames}" "━${ESC}[2m━"
  check "following ffmpeg's progress" test "${#${(@M)percents:#([1-9]|[1-9][0-9])}}" -ge 1
  check "against the length of what is kept, at its speed" test "${#${(@M)percents:#([5-9][0-9]|100)}}" -ge 1
  check "with the time left once there is enough to go on" test "$left" -ge 1
  check "then cleared, and the result written in its place" contains "$screen" \
    $'\r'"${ESC}[K${ESC}[?25h      ${ESC}[32mdone     ${ESC}[0m $(size_of "$work/clip.mov") -> $(size_of "$work/clip.mp4"), cut applied"
  check "the cursor hidden while it is drawn" contains "${screen%%${ESC}\[36mencoding*}" "${ESC}[?25l"
  after="${screen##*${ESC}\[\?25l}"
  check "and shown again after" contains "$after" "${ESC}[?25h"
  check "the log has no bar" not_logged "$box" '━'
  check "and no colour" not_logged "$box" "$ESC"
}

# The parts of a merged set agree, so their join is a copy too quick to watch; here it has to be
# re-encoded, by an ffmpeg that cannot join by copying and does everything else as the real one.
test_run_merge_on_a_terminal_draws_the_join_as_a_bar() {
  local box tools work file screen frame rest
  local -a frames percents
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  print -rl -- '#!/bin/zsh' '[[ " $* " == *" -f concat "* ]] && exit 1' "exec ${(qq)FFMPEG} \"\$@\"" \
    > "$tools/ffmpeg"
  chmod +x "$tools/ffmpeg"
  work="$(scratch)"
  cp "$FIXTURES/tall.mov" "$work/1 a.mov"
  cp "$FIXTURES/tall.mov" "$work/2 b.mov"
  file="$(make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov")"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(< "$tools/screen")"
  frames=(${(f)"$(drawn_frames "$screen" joining)"})
  for frame in ${(f)"$(print -rl -- "${frames[@]}" | plain)"}; do
    [[ "$frame" == "      joining   $BAR30 "* ]] || continue
    rest="${frame#"      joining   $BAR30 "}"
    percents+=("${${rest##[[:space:]]#}%%\%*}")
  done

  check "joins by re-encoding" logged "$box" "merged 2 clips into ${${file:t}%.edit.txt}-merged.mp4 (re-encoded)"
  check "drawn as a bar under joining, in magenta" contains "${(F)frames}" "      ${ESC}[35mjoining  ${ESC}[0m ${ESC}[35m"
  check "of 30 cells and the percent" test "${#percents}" -ge 1 -a "${#percents}" = "${#frames}"
  check "against how long the parts last together" test "${#${(@M)percents:#([1-9]|[1-9][0-9]|100)}}" -ge 1
  check "then the join in its place" contains "$screen" \
    $'\r'"${ESC}[K${ESC}[?25h      ${ESC}[35mjoined   ${ESC}[0m 2 clips into ${${file:t}%.edit.txt}-merged.mp4 (re-encoded)"
}

# A stream with no container around it states no length, so there is nothing to measure a bar
# against.
test_run_on_a_terminal_spins_for_a_recording_that_does_not_say_how_long_it_is() {
  local box tools work file screen frame spun=0
  local -a frames
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  "$FFMPEG" -nostdin -v error -i "$FIXTURES/tall.mov" -c copy -bsf:v h264_mp4toannexb -f h264 "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(< "$tools/screen")"
  frames=(${(f)"$(drawn_frames "$screen" encoding | plain)"})
  for frame in "${frames[@]}"; do
    [[ "$frame" == "      encoding  "(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏) ]] && ((++spun))
  done

  check "the recording states no length" test "$(duration "$work/clip.mov")" = N/A
  check "spins instead of a bar" test "$spun" -ge 1 -a "$spun" = "${#frames}"
  check "turning" test "${#${(@u)frames}}" -ge 2
  check "with no percent to show" lacks "${(F)frames}" "%"
  check "then the result in its place" contains "$screen" \
    $'\r'"${ESC}[K${ESC}[?25h      ${ESC}[32mdone     ${ESC}[0m $(size_of "$work/clip.mov") -> $(size_of "$work/clip.mp4")"
  check "and the cursor shown again" contains "${screen##*${ESC}\[\?25l}" "${ESC}[?25h"
}

# TERM stops a run in the middle of an encode, as kill does. Closing the window sends HUP, which
# tests/21 sends a merged run.
test_a_run_stopped_on_a_terminal_shows_the_cursor_again() {
  local box tools work file tmp runner pid screen code=0 _
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/big.mov" "$work/clip.mov"
  file="$(make_edit "$box" "$tools" "$work/clip.mov")"

  in_terminal "$tools" env -u NO_COLOR TMPDIR="$tmp" PATH="$tools:$PATH" SHRINKIT_DIR="$box" \
    SHRINKIT_REPO= zsh -c 'print $$ > "$1"; shift; exec "$@"' zsh "$tools/pid" \
    zsh "$OPTIMIZER" run "$file" &
  runner=$!
  for _ in {1..400}; do
    grep -q '━' "$tools/screen" 2> /dev/null && break
    sleep 0.05
  done
  pid="$(< "$tools/pid")"
  kill -TERM "$pid"
  wait "$runner" || code=$?
  screen="$(< "$tools/screen")"

  check "was drawing the bar" contains "$screen" '━'
  check "with the cursor hidden" contains "$screen" "${ESC}[?25l"
  check "clears the bar and shows the cursor again once stopped" \
    contains "${screen##*${ESC}\[\?25l}" $'\r'"${ESC}[K${ESC}[?25h"
  check "makes nothing" missing "$work/clip.mp4"
  check "and leaves nothing in the temporary folder" empty_dir "$tmp"
}
