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

  make_edit "$box" "$tools" "$work/a-second.mov" "$work/2 bug.mov" "$work/z-first.mov" "$work/1 intro.mov" \
    > /dev/null

  check "one block per recording, numbered takes first, then in the order they were shot" \
    test "$(headers_of "$tools/given")" = $'[1 intro.mov]\n[2 bug.mov]\n[z-first.mov]\n[a-second.mov]'
  check "merge = false above the first block" \
    test "$(grep -v -e '^#' -e '^$' "$tools/given" | head -1)" = 'merge = false'
}

# The name comes from the set of recordings (SPEC.md, The edit file's name). They are recorded c, a,
# b, so the order they join in is neither the order they are given in nor the order name_for sorts
# their paths in.
test_edit_names_the_file_for_the_set_of_recordings_in_any_order() {
  local box tools work three
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-green.mov" "$work/c.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-red.mov" "$work/a.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/b.mov" 2026-01-01T10:10:00
  three="$work/$(name_for "$work/a.mov" "$work/b.mov" "$work/c.mov")"

  run_edit "$box" "$tools" "$work/b.mov" "$work/a.mov" "$work/c.mov" 2> /dev/null
  check "names the file for the three recordings" test "$(edited "$tools")" = "$three"
  check "and writes it" exists "$three"

  rm -f "$three"
  run_edit "$box" "$tools" "$work/c.mov" "$work/b.mov" "$work/a.mov" 2> /dev/null
  check "the same name whatever order they are given in" test "$(edited "$tools")" = "$three"

  run_edit "$box" "$tools" "$work/a.mov" "$work/b.mov" 2> /dev/null
  check "another set, another name" \
    test "$(edited "$tools")" = "$work/$(name_for "$work/a.mov" "$work/b.mov")"
  check "not the three's" test "$(edited "$tools")" != "$three"
}

# A Terminal window sets a locale and a Quick Action need not, and the two can sort paths
# differently: B.mov before a.mov byte by byte, after it in uk_UA.
test_edit_names_the_file_the_same_in_every_locale() {
  local box tools work want
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/a.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/B.mov" 2026-01-01T10:05:00
  want="$work/$(name_for "$work/a.mov" "$work/B.mov")"

  check "uk_UA really sorts a.mov first" test "$(print -rl B.mov a.mov | LC_ALL=uk_UA.UTF-8 sort | head -1)" = a.mov
  LC_ALL=uk_UA.UTF-8 run_edit "$box" "$tools" "$work/a.mov" "$work/B.mov" 2> /dev/null
  check "in uk_UA" test "$(edited "$tools")" = "$want"
  rm -f "$want"
  LC_ALL=C run_edit "$box" "$tools" "$work/a.mov" "$work/B.mov" 2> /dev/null
  check "and in C" test "$(edited "$tools")" = "$want"
}

# The same set of recordings reopens its file: whatever was typed into it stays, and nothing is
# written over it.
test_edit_opens_the_file_of_the_same_recordings_as_it_was_left() {
  local box tools work file before saved
  local -a files
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'add a.mov "speed = 3"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/b.mov"
  file="$(make_edit "$box" "$tools" "$work/a.mov" "$work/b.mov")"
  # Typed into it later, to run it again another day, and saved a while ago.
  print -r -- 'crf = 20' >> "$file"
  touch -t 202601011000 "$file"
  before="$(< "$file")"
  saved="$(stat -f %m "$file")"

  stub_editor "$tools" editor 'exit 1'
  run_edit "$box" "$tools" "$work/b.mov" "$work/a.mov" 2> /dev/null

  check "hands the editor the same file" test "$(edited "$tools")" = "$file"
  check "as it was left" test "$(< "$tools/given")" = "$before"
  check "keeping what it holds" test "$(< "$file")" = "$before"
  check "and when it was saved" test "$(stat -f %m "$file")" = "$saved"
  files=("$work"/*.edit.txt(N))
  check "and writes no other" test "${#files}" = 1
}

# A folder reached through a symlink is the same set of recordings as its real path, and names the
# same file: /tmp is /private/tmp, and Finder hands over the real path.
test_edit_names_the_file_the_same_through_a_symlinked_folder() {
  local box tools work link file
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/b.mov"
  link="$(scratch)/link"
  ln -s "${work:A}" "$link"

  run_edit "$box" "$tools" "$link/a.mov" "$link/b.mov" 2> /dev/null
  file="$(edited "$tools")"
  run_edit "$box" "$tools" "${work:A}/a.mov" "${work:A}/b.mov" 2> /dev/null

  check "names it after the real paths" \
    test "${file:t}" = "$(print -rl -- "${work:A}/a.mov" "${work:A}/b.mov" | LC_ALL=C sort | shasum -a 256 | cut -c1-6 | sed 's/^/shrinkit-/;s/$/.edit.txt/')"
  check "and the real path opens that same file" test "$(edited "$tools")" = "${work:A}/${file:t}"
}

# Two recordings from two folders recorded in the same second come first in the order they were
# selected in, so the file an earlier edit left beside one of them is looked for in both folders.
test_edit_opens_the_file_of_the_same_recordings_from_either_folder() {
  local box tools one two file
  local -a files
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  one="$(scratch)"
  two="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$one/a.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$two/b.mov" 2026-01-01T10:00:00

  run_edit "$box" "$tools" "$one/a.mov" "$two/b.mov" 2> /dev/null
  file="$(edited "$tools")"
  run_edit "$box" "$tools" "$two/b.mov" "$one/a.mov" 2> /dev/null

  check "the first edit left it beside the first selected" test "${file:h}" = "$one"
  check "the other order opens that file" test "$(edited "$tools")" = "$file"
  files=("$one"/*.edit.txt(N) "$two"/*.edit.txt(N))
  check "and no second one is written" test "${#files}" = 1
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

  check "writes the file beside the first recording" \
    exists "$here/$(name_for "$here/first.mov" "$there/second.mov")"
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
  local box tools work file out code=0
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
  file="$(edited "$tools")"

  check "exits 1" test "$code" = 1
  made=("$work"/*.mp4(N))
  check "runs nothing" test "${#made}" = 0
  check "keeps the file" grep -qx 'speed = 3' "$file"
  check "and says where it is" contains "$out" "The file stays: $file"
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
  check "VISUAL first" \
    test "$(tail -1 "$tools/editor.log")" = "visual $work/$(name_for "$work/clip.mov")"

  run_edit "$box" "$tools" "$work/clip.mov" 2> /dev/null
  check "then EDITOR" grep -q '^editor ' <<< "$(tail -1 "$tools/editor.log")"

  env -u VISUAL -u EDITOR PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" edit "$work/clip.mov" 2> /dev/null
  check "then vi, as git does" grep -q '^vi ' <<< "$(tail -1 "$tools/editor.log")"
}

# SPEC.md, At most 10 recordings.
test_edit_takes_at_most_ten_recordings() {
  local box tools work out code=0 i
  local -a takes files
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'exit 1'
  work="$(scratch)"
  for i in {1..11}; do
    cp "$FIXTURES/take-red.mov" "$work/$i take.mov"
    takes+=("$work/$i take.mov")
  done

  out="$(run_edit "$box" "$tools" "${takes[@]}" 2>&1)" || code=$?
  files=("$work"/*.edit.txt(N))

  check "refuses 11" test "$code" = 2
  check "saying why" contains "$out" "edit takes up to 10 recordings at a time; 11 were given"
  check "and in the log" logged "$box" "edit takes up to 10 recordings at a time; 11 were given"
  check "writes no edit file" test "${#files}" = 0
  check "and opens no editor" missing "$tools/editor.log"

  run_edit "$box" "$tools" "${takes[@]:0:10}" 2> /dev/null
  check "takes 10" test "$(headers_of "$tools/given" | wc -l | tr -d ' ')" = 10
}
