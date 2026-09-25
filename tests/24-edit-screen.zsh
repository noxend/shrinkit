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
  check "a result in green" contains "$screen" "      ${ESC}[32mdone     ${ESC}[0m 1 a.mp4 ("
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
  out="$work/1 a-merged.mp4"

  in_terminal "$tools" env -u NO_COLOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO= \
    zsh "$OPTIMIZER" run "$file"
  screen="$(tr -d '\r' < "$tools/screen")"

  check "the join headed in bold" contains "$screen" $'\n'"${ESC}[1m[join]${ESC}[0m 2 parts"$'\n'
  check "and joined in magenta" contains "$screen" \
    "      ${ESC}[35mjoined   ${ESC}[0m 2 clips into 1 a-merged.mp4 (streams copied)"
  check "Done in bold green, the size in bold, how long it plays dim" contains "$screen" \
    $'\n'"${ESC}[32m${ESC}[1mDone${ESC}[0m  ${ESC}[1m$(du -h "$out" | cut -f1 | tr -d ' ')${ESC}[0m  ${ESC}[2m$(printf '%.1fs' "$(duration "$out")")${ESC}[0m"$'\n'
  check "then the file, its folder dim" contains "$screen" $'\n'"      ${ESC}[2m$work/${ESC}[0m1 a-merged.mp4"$'\n'
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
  check "and what came of it" contains "$screen" $'\n      done      clip.mp4 ('
}
