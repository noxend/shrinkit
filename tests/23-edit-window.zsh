# Sourced by tests/run-tests.sh: the Terminal window a right-click on recordings opens, and the
# launcher setup writes for it. The window reads Enter from its stdin, which every test here feeds
# itself, and opens TextEdit and Finder through an open that only writes down what it was asked.

# The one sequence a window prints before anything else: the cursor home, the screen cleared, and
# what scrolled off it cleared too.
CLEAN_SCREEN=$'\e[H\e[2J\e[3J'

running() {
  kill -0 "$1" 2> /dev/null
}

# wait_for_line <file> <pattern>: up to ten seconds for a line matching pattern to be in file.
wait_for_line() {
  local _
  for _ in {1..200}; do
    grep -q -- "$2" "$1" 2> /dev/null && return 0
    sleep 0.05
  done
  return 1
}

test_the_window_starts_on_a_clean_screen() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"

  out="$(run_window "$box" "$tools" --wait "$file" < /dev/null)"

  check "clears the screen and what scrolled off it before anything else" \
    test "${out[1,${#CLEAN_SCREEN}]}" = "$CLEAN_SCREEN"
  check "then names the file" test "${${(f)out}[1]}" = "$CLEAN_SCREEN$file"
  check "and says what to do with it" contains "$out" \
    $'\nEdit the file in TextEdit, save it (Cmd-S), then press Enter here to run it.\n'
  check "and how to leave it for later" contains "$out" \
    $'\nCtrl-C cancels; the file stays, and \'shrinkit run <file>\' runs it later.\n'
}

test_the_window_opens_the_file_in_textedit_then_waits_for_enter() {
  local box tools work file pid keep code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  # What is typed into TextEdit and saved while the window waits.
  stub_textedit "$tools" 'speed = 4'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"
  mkfifo "$tools/keys"
  # Held open, so the window reads nothing until the test presses Enter, and no end of input either.
  # The window gets no copy of it, or closing it here would never end its input.
  exec {keep}<> "$tools/keys"

  HOME="$box/home" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" run --wait "$file" < "$tools/keys" {keep}>&- > "$tools/screen" 2>&1 &
  pid=$!
  wait_for_line "$tools/open.log" '^-e '
  sleep 1

  check "opens the file in TextEdit" test "$(< "$tools/open.log")" = "-e | $file"
  check "then waits" running "$pid"
  check "running nothing before Enter" missing "$work/clip.mp4"
  # One Enter, then the end of the input, so a window that waits for more stops instead of hanging.
  print -u "$keep"
  exec {keep}>&-
  wait "$pid" || code=$?

  check "runs it on Enter" exists "$work/clip.mp4"
  check "as it was saved in TextEdit" duration_near "$work/clip.mp4" 3
  check "saying nothing about a file never saved" lacks "$(< "$tools/screen")" "has not been saved"
  check "and exits 0" test "$code" = 0
}

test_the_window_runs_nothing_when_enter_never_comes() {
  local box tools work file out pid keep code=0 _
  local -a made
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"

  out="$(run_window "$box" "$tools" --wait "$file" < /dev/null)" || code=$?

  check "at the end of the input, says so" test "${${(f)out}[-1]}" = "Nothing was run."
  check "and exits 1" test "$code" = 1
  check "having opened the file in TextEdit all the same" test "$(< "$tools/open.log")" = "-e | $file"

  # Ctrl-C while it waits: the terminal sends INT to the window's process.
  : > "$tools/open.log"
  mkfifo "$tools/keys"
  exec {keep}<> "$tools/keys"
  HOME="$box/home" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" run --wait "$file" < "$tools/keys" {keep}>&- > /dev/null 2>&1 &
  pid=$!
  wait_for_line "$tools/open.log" '^-e ' && sleep 0.5
  code=0
  kill -INT "$pid"
  for _ in {1..40}; do
    running "$pid" || break
    sleep 0.05
  done
  exec {keep}>&-
  wait "$pid" || code=$?
  check "Ctrl-C ends it with the signal's status" test "$code" = 130

  made=("$work"/*.mp4(N))
  check "and neither ran anything" test "${#made}" = 0
  check "nor logged a run" not_logged "$box" 'run    '
}

test_the_window_warns_once_about_a_file_never_saved() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"
  file="$work/clip.edit.txt"

  out="$(print | run_window "$box" "$tools" --wait "$file")"

  check "says the file was never saved" contains "$out" \
    $'\nclip.edit.txt has not been saved since it was made. Save it and press Enter, or press Enter to run it as it is.\n'
  check "then waits for Enter again" test "${${(f)out}[-1]}" = "Nothing was run."
  check "running nothing" missing "$work/clip.mp4"

  out="$(printf '\n\n' | run_window "$box" "$tools" --wait "$file")"

  check "says it once" test "$(grep -c 'has not been saved' <<< "$out")" = 1
  check "and runs it as it is on the second Enter" exists "$work/clip.mp4"
}

test_the_window_reveals_the_result_and_says_how_to_run_it_again() {
  local box tools work file out
  box="$(sandbox)"
  settings "$box"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor
  stub_textedit "$tools"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  file="$work/1 a.edit.txt"

  out="$(print | run_window "$box" "$tools" --wait "$file")"

  check "runs the file" contains "$out" $'\nRunning 1 a.edit.txt: 2 recordings, merge = false\n'
  check "says how to run it again" test "${${(f)out}[-1]}" = "To run it again: shrinkit run ${(qq)file}"
  check "and shows what came out in Finder" \
    test "$(tail -1 "$tools/open.log")" = "-R | $work/1 a.mp4 | $work/2 b.mp4"
}

# One request per right-click, holding the path of its edit file (SPEC.md, How the window is
# started), and one window per request: each takes the oldest one there is. The launcher itself is
# run here, as Terminal runs it, with open stubbed and its input at an end, so it runs nothing.
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
    test "${${(f)first}[1]}" = "$CLEAN_SCREEN$work/a.edit.txt"
  check "the second takes the next" test "${${(f)second}[1]}" = "$CLEAN_SCREEN$work/b.edit.txt"
  check "each opening its own file in TextEdit" \
    test "$(< "$tools/open.log")" = "-e | $work/a.edit.txt"$'\n'"-e | $work/b.edit.txt"
  check "a third finds none waiting" test "$third" = \
    "${CLEAN_SCREEN}No edit file is waiting. Select recordings in Finder and pick shrinkit: edit."
  check "and exits 1" test "$code" = 1
  check "leaving no request behind" empty_dir "$queue"
}
