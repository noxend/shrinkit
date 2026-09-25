# Sourced by tests/run-tests.sh: shrinkit edit from a terminal, the file it writes and the editor.

test_edit_writes_one_block_per_recording_in_merge_order() {
  local box tools work
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/z-first.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/a-second.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-green.mov" "$work/2 bug.mov" 2026-01-01T11:00:00
  recorded_copy "$FIXTURES/take-green.mov" "$work/1 intro.mov" 2026-01-01T12:00:00

  make_edit "$box" "$tools" "$work/a-second.mov" "$work/2 bug.mov" "$work/z-first.mov" "$work/1 intro.mov"

  check "one block per recording, numbered takes first, then in the order they were shot" \
    test "$(headers_of "$tools/given")" = $'[1 intro.mov]\n[2 bug.mov]\n[z-first.mov]\n[a-second.mov]'
  check "merge = false above the first block" \
    test "$(grep -v -e '^#' -e '^$' "$tools/given" | head -1)" = 'merge = false'
  check "the file is named after the first recording" exists "$work/1 intro.edit.txt"
  check "and is what the editor was handed" test "$(< "$tools/editor.log")" = "editor $work/1 intro.edit.txt"
}

test_edit_writes_the_file_beside_the_first_recording_and_never_over_another() {
  local box tools work first
  local -a second
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add clip.mov "speed = 3"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  first="$work/clip.edit.txt"

  run_edit "$box" "$tools" "$work/clip.mov" > /dev/null
  check "writes clip.edit.txt beside the recording" exists "$first"
  check "which keeps what was typed into it" grep -qx 'speed = 3' "$first"
  # Typed into it later, to run it again another day.
  print -r -- 'crf = 20' >> "$first"

  run_edit "$box" "$tools" "$work/clip.mov" > /dev/null
  second=("$work"/clip-<->.edit.txt(N))
  check "a second edit writes a new file beside the first" test "${#second}" = 1
  check "hands that one to the editor" test "$(tail -1 "$tools/editor.log")" = "editor ${second[1]-}"
  check "and leaves the first as it was" test "$(tail -1 "$first")" = 'crf = 20'
}

test_edit_names_each_recordings_length_and_the_presets_there_are() {
  local box tools work
  box="$(sandbox)"
  settings "$box"
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  print -r -- 'crf = 32' > "$box/presets/tiny.conf"
  print -r -- 'tiny' > "$box/presets/.not-in-menu"
  tools="$(scratch)"
  stub_tools "$tools"
  # The editor gives up, so nothing runs: this test is about the file it was handed.
  stub_editor "$tools" editor 'exit 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  cp "$FIXTURES/take-red.mov" "$work/short.mov"
  # A recording ffprobe cannot read, and so cannot say the length of.
  print -r -- 'not a movie' > "$work/broken.mov"

  run_edit "$box" "$tools" "$work/clip.mov" "$work/short.mov" "$work/broken.mov" 2> /dev/null

  check "says how many recordings and how to run it" test "$(head -1 "$tools/given")" = \
    "# shrinkit edit: 3 recordings. Edit this file, save it and close the editor to run it. Delete every block to cancel."
  check "names the presets there are" \
    grep -qxF '#   preset = sharp       one of: sharp, tiny' "$tools/given"
  check "gives the length of a 12 second recording" grep -qxF '# clip.mov is 0:12 long' "$tools/given"
  check "and of a 2 second one" grep -qxF '# short.mov is 0:02 long' "$tools/given"
  check "and none for one whose length is not stated" test "$(grep -c 'broken.mov is' "$tools/given")" = 0

  box="$(sandbox)"
  settings "$box"
  run_edit "$box" "$tools" "$work/short.mov" 2> /dev/null
  check "with no preset, says so" grep -qxF '#   preset = sharp       no presets yet' "$tools/given"
  check "and counts one recording as one" \
    grep -q '^# shrinkit edit: 1 recording\. ' "$tools/given"
}

test_edit_names_a_recording_in_another_folder_by_its_path() {
  local box tools here there
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  here="$(scratch)"
  there="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$here/first.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$there/second.mov" 2026-01-01T10:05:00

  run_edit "$box" "$tools" "$there/second.mov" "$here/first.mov" 2> /dev/null

  check "writes the file beside the first recording" exists "$here/first.edit.txt"
  check "names the one beside it by its name, the other by its path" \
    test "$(headers_of "$tools/given")" = "[first.mov]"$'\n'"[$there/second.mov]"
}

test_edit_without_a_video_is_refused() {
  local box tools work out code=0
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  print -r -- 'not a recording' > "$work/notes.txt"

  out="$(run_edit "$box" "$tools" "$work/notes.txt" 2>&1)" || code=$?

  check "says what it skipped" contains "$out" "notes.txt is not a video (.mov, .mp4 or .m4v)"
  check "and that edit needs a video" contains "$out" "edit needs at least one video (.mov, .mp4 or .m4v)"
  check "exits 2" test "$code" = 2
  check "opens no editor" missing "$tools/editor.log"
  check "and writes no file" test "$(ls "$work")" = notes.txt

  code=0
  run_edit "$box" "$tools" > /dev/null 2>&1 || code=$?
  check "named nothing at all, exits 2 too" test "$code" = 2
}

test_edit_stops_when_the_editor_fails() {
  local box tools work out code=0
  local -a made
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  # vi's :cq, or a GUI editor's window closed with an error.
  stub_editor "$tools" editor 'add clip.mov "speed = 3"' 'exit 1'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"

  out="$(run_edit "$box" "$tools" "$work/clip.mov" 2>&1)" || code=$?

  check "exits 1" test "$code" = 1
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "keeps the file" grep -qx 'speed = 3' "$work/clip.edit.txt"
  check "and says where it is" contains "$out" "$work/clip.edit.txt"
}

test_edit_opens_visual_then_editor_then_vi() {
  local box tools work name
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  for name in visual editor vi; do stub_editor "$tools" "$name" 'exit 1'; done
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"

  VISUAL="$tools/visual" EDITOR="$tools/editor" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" edit "$work/clip.mov" 2> /dev/null
  check "VISUAL first" test "$(tail -1 "$tools/editor.log")" = "visual $work/clip.edit.txt"

  run_edit "$box" "$tools" "$work/clip.mov" 2> /dev/null
  check "then EDITOR" grep -q '^editor ' <<< "$(tail -1 "$tools/editor.log")"

  env -u VISUAL -u EDITOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" edit "$work/clip.mov" 2> /dev/null
  check "then vi, as git does" grep -q '^vi ' <<< "$(tail -1 "$tools/editor.log")"
}
