# Sourced by tests/run-tests.sh: the two right-click entries and the Terminal window. shrinkit: edit
# writes the edit file and opens it in TextEdit; shrinkit: run leaves a request for each edit file it
# is handed and opens a window on the launcher setup writes; the window takes one request and runs
# its file. open and osascript only write down what they were asked.

# The one sequence a window prints before anything else: the cursor home, the screen cleared, and
# what scrolled off it cleared too.
CLEAN_SCREEN=$'\e[H\e[2J\e[3J'

# A request left the way shrinkit: run leaves one, then the window that takes it, as the launcher
# runs it; its input is at an end, so nothing it could wait for ever comes.
test_the_window_runs_its_file_at_once_on_a_clean_screen() {
  local box tools work file out code=0
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"
  run_window "$box" "$tools" --finder "$file"

  out="$(run_window "$box" "$tools" --next < /dev/null)" || code=$?

  check "clears the screen and what scrolled off it before anything else" \
    test "${out[1,${#CLEAN_SCREEN}]}" = "$CLEAN_SCREEN"
  check "then runs the file" \
    test "${${(f)out}[1]}" = "${CLEAN_SCREEN}Running clip.edit.txt: 1 recording, merge = false"
  check "with no Enter pressed" exists "$work/clip.mp4"
  check "saying nothing about a file never saved" lacks "$out" "has not been saved"
  check "opening nothing in TextEdit" lacks "$(< "$tools/open.log")" "-e | "
  check "and exits 0" test "$code" = 0
}

test_the_window_reveals_the_result_and_says_how_to_run_it_again() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  file="$work/1 a.edit.txt"
  run_window "$box" "$tools" --finder "$file"

  out="$(run_window "$box" "$tools" --next < /dev/null)"

  check "runs the file" contains "$out" $'Running 1 a.edit.txt: 2 recordings, merge = false\n'
  check "says how to run it again" test "${${(f)out}[-1]}" = "To run it again: shrinkit run ${(qq)file}"
  check "and shows what came out in Finder" \
    test "$(tail -1 "$tools/open.log")" = "-R | $work/1 a.mp4 | $work/2 b.mp4"
}

# One request per edit file (SPEC.md, How the window is started), and one window per request: each
# takes the oldest one there is. The launcher itself is run here, as Terminal runs it, with open
# stubbed.
test_each_window_takes_one_request() {
  local box tools work support launcher queue first second third code=0
  box="$(installed_box)"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/b.mov"
  make_edit "$box/work" "$tools" "$work/a.mov"
  make_edit "$box/work" "$tools" "$work/b.mov"
  support="$box/home/Library/Application Support/shrinkit"
  launcher="$support/shrinkit edit.command"
  queue="$support/edit-queue"
  mkdir -p "$queue"
  print -r -- "$work/gone.edit.txt" > "$queue/one"
  print -r -- "$work/a.edit.txt" > "$queue/two"
  print -r -- "$work/b.edit.txt" > "$queue/three"
  touch -t 202601011000 "$queue/one"
  touch -t 202601011001 "$queue/two"
  touch -t 202601011002 "$queue/three"

  first="$(HOME="$box/home" PATH="$tools:$PATH" "$launcher" < /dev/null)"
  second="$(HOME="$box/home" PATH="$tools:$PATH" "$launcher" < /dev/null)"
  third="$(HOME="$box/home" PATH="$tools:$PATH" "$launcher" < /dev/null)" || code=$?

  check "the first window takes the oldest request whose file is there" \
    test "${${(f)first}[1]}" = "${CLEAN_SCREEN}Running a.edit.txt: 1 recording, merge = false"
  check "the second takes the next" \
    test "${${(f)second}[1]}" = "${CLEAN_SCREEN}Running b.edit.txt: 1 recording, merge = false"
  check "each running its own file" \
    test "$(< "$tools/open.log")" = "-R | $work/a.mp4"$'\n'"-R | $work/b.mp4"
  check "a third finds none waiting" test "$third" = \
    "${CLEAN_SCREEN}No edit file is waiting. Select one in Finder and pick shrinkit: run."
  check "and exits 1" test "$code" = 1
  check "leaving no request behind" empty_dir "$queue"
}

# --------------------------------------------------------------------- shrinkit: edit

test_the_edit_entry_opens_the_file_in_textedit_and_nothing_else() {
  local box tools work support file
  box="$(installed_box)"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/red.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/blue.mov" 2026-01-01T10:05:00
  support="$box/home/Library/Application Support/shrinkit"
  file="$work/red.edit.txt"

  run_entry "$box" "$tools" edit "$work/blue.mov" "$work/red.mov"

  check "opens the edit file in TextEdit, and no player and no Terminal window" \
    test "$(< "$tools/open.log")" = "-e | $file"
  check "leaving no request for a window" empty_dir "$support/edit-queue"
}

test_the_edit_entry_writes_the_file_beside_the_first_recording() {
  local box tools work file
  box="$(installed_box)"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 intro.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 bug.mov"
  print -r -- 'not a recording' > "$work/notes.txt"
  file="$work/1 intro.edit.txt"

  run_entry "$box" "$tools" edit "$work/notes.txt" "$work/2 bug.mov" "$work/1 intro.mov" 2> /dev/null

  check "writes <first recording>.edit.txt beside it" exists "$file"
  check "saying how it is run" test "$(head -1 "$file")" = \
    "# shrinkit edit: 2 recordings. Edit this file, save it, then right-click it in Finder and pick shrinkit: run."
  check "with a block per recording, in the order they join in" \
    test "$(headers_of "$file")" = $'[1 intro.mov]\n[2 bug.mov]'
}

test_the_edit_entry_without_a_video_says_so() {
  local box tools work code=0
  box="$(installed_box)"
  print -r -- 'notify_sound = Ping' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  print -r -- 'not a recording' > "$work/notes.txt"

  run_entry "$box" "$tools" edit "$work/notes.txt" 2> /dev/null || code=$?

  check "says so in a banner, since nothing else it says is seen" \
    test "$(< "$tools/osascript.log")" = "banner shrinkit | shrinkit: edit needs a video | Ping"
  check "exits 2" test "$code" = 2
  check "opens nothing" missing "$tools/open.log"
  check "and writes nothing" test "$(ls "$work")" = notes.txt
}

test_the_edit_entry_opens_nothing_where_it_cannot_write() {
  local box tools work code=0
  box="$(installed_box)"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  chmod a-w "$work"

  run_entry "$box" "$tools" edit "$work/clip.mov" 2> /dev/null || code=$?
  chmod u+w "$work"

  check "says so in a banner naming the folder" \
    test "$(< "$tools/osascript.log")" = "banner shrinkit | shrinkit: edit cannot write in $work | Glass"
  check "opens nothing" missing "$tools/open.log"
  check "and exits 1" test "$code" = 1
}

# --------------------------------------------------------------------- shrinkit: run

test_the_run_entry_opens_a_window_for_each_edit_file() {
  local box tools work support launcher
  box="$(installed_box)"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/b.mov"
  make_edit "$box/work" "$tools" "$work/a.mov"
  make_edit "$box/work" "$tools" "$work/b.mov"
  print -r -- 'not an edit file' > "$work/notes.txt"
  support="$box/home/Library/Application Support/shrinkit"
  launcher="$support/shrinkit edit.command"

  run_entry "$box" "$tools" run "$work/a.edit.txt" "$work/notes.txt" "$work/a.mov" "$work/b.edit.txt"

  check "opens one Terminal window on the launcher for each edit file" \
    test "$(< "$tools/open.log")" = "-a | Terminal | $launcher"$'\n'"-a | Terminal | $launcher"
  check "leaving each window one of them to take" \
    test "$(cat "$support/edit-queue"/*(N.) | sort)" = "$work/a.edit.txt"$'\n'"$work/b.edit.txt"

  : > "$tools/open.log"
  (cd "$box" && HOME="$box/home" PATH="$tools:$PATH" "$launcher" < /dev/null > /dev/null)
  (cd "$box" && HOME="$box/home" PATH="$tools:$PATH" "$launcher" < /dev/null > /dev/null)

  check "which run one file each" \
    test "$(sort "$tools/open.log")" = "-R | $work/a.mp4"$'\n'"-R | $work/b.mp4"
  check "and take their requests, so no other window does" empty_dir "$support/edit-queue"
}

test_the_run_entry_without_an_edit_file_says_so() {
  local box tools work support code=0
  box="$(installed_box)"
  print -r -- 'notify_sound = Ping' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  print -r -- 'not an edit file' > "$work/notes.txt"
  support="$box/home/Library/Application Support/shrinkit"

  run_entry "$box" "$tools" run "$work/clip.mov" "$work/notes.txt" 2> /dev/null || code=$?

  check "says what it takes in a banner" test "$(< "$tools/osascript.log")" = \
    "banner shrinkit | shrinkit: run takes an edit file (<first recording>.edit.txt) | Ping"
  check "exits 2" test "$code" = 2
  check "opens nothing" missing "$tools/open.log"
  check "and leaves no request" empty_dir "$support/edit-queue"
}

test_the_run_entry_says_when_its_terminal_window_does_not_open() {
  local box tools work file said code=0
  box="$(installed_box)"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/it's.mov"
  make_edit "$box/work" "$tools" "$work/it's.mov"
  file="$work/it's.edit.txt"
  # Terminal does not open the launcher.
  print -rl -- '#!/bin/zsh' "print -r -- \"\${(j: | :)@}\" >> ${(qq)tools}/open.log" \
    '[[ "$1" != -a ]]' > "$tools/open"
  said="shrinkit: run could not open a Terminal window. To run the file: shrinkit run ${(qq)file}"

  run_entry "$box" "$tools" run "$file" 2> /dev/null || code=$?

  check "says so in a banner, with the command that runs the file by hand" \
    test "$(< "$tools/osascript.log")" = "banner shrinkit | $said | Glass"
  check "and in the log" test "$(grep -c -F -- "$said" "$box/work/.logs/optimizer.log")" = 1
  check "and exits 1" test "$code" = 1
}

# Each window takes the oldest request, so one left by a run whose window never opened would be
# taken by the next run's window instead of that run's own.
test_a_run_whose_window_does_not_open_leaves_no_request() {
  local box tools work support
  box="$(installed_box)"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/first.mov"
  cp "$FIXTURES/take-blue.mov" "$work/second.mov"
  make_edit "$box/work" "$tools" "$work/first.mov"
  make_edit "$box/work" "$tools" "$work/second.mov"
  support="$box/home/Library/Application Support/shrinkit"
  print -rl -- '#!/bin/zsh' "print -r -- \"\${(j: | :)@}\" >> ${(qq)tools}/open.log" \
    '[[ "$1" != -a ]]' > "$tools/open"

  run_entry "$box" "$tools" run "$work/first.edit.txt" 2> /dev/null

  check "leaves no request in the queue" empty_dir "$support/edit-queue"

  # Terminal opens again for the next run.
  stub_tools "$tools"
  run_entry "$box" "$tools" run "$work/second.edit.txt"
  (cd "$box" && HOME="$box/home" PATH="$tools:$PATH" "$support/shrinkit edit.command" < /dev/null > /dev/null)

  check "so the next window runs that run's own file" \
    test "$(tail -1 "$tools/open.log")" = "-R | $work/second.mp4"
}

# --------------------------------------------------------------------- both

# The folder, the program and the recordings reach the entries' commands, the launcher and the
# window as the words they are, never as code.
test_the_entries_take_names_as_written() {
  local box folder tools work support
  box="$(scratch)"
  setup_box "$box"
  folder="$box/w \$(touch folder-ran)"
  run_setup "$box" "$folder" > /dev/null 2>&1
  print -r -- 'notify = false' >> "$folder/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$box/clips \$(touch clip-ran)"
  mkdir -p "$work"
  cp "$FIXTURES/take-red.mov" "$work/it's.mov"
  support="$box/home/Library/Application Support/shrinkit"

  run_entry "$box" "$tools" edit "$work/it's.mov"
  run_entry "$box" "$tools" run "$work/it's.edit.txt"
  (cd "$box" && HOME="$box/home" PATH="$tools:$PATH" "$support/shrinkit edit.command" < /dev/null > /dev/null)

  check "runs nothing named in the folder" missing "$box/folder-ran"
  check "or in the recording's" missing "$box/clip-ran"
  check "writes the file beside the recording" exists "$work/it's.edit.txt"
  check "and the window runs it" test "$(tail -1 "$tools/open.log")" = "-R | $work/it's.mp4"
}
