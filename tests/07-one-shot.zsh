# Sourced by tests/run-tests.sh: files named on the command line, flags, temp parts, interruptions.

test_one_shot_optimizes_a_file_in_place() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  # a file living outside the input folder, like something you right-click in Finder
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov"

  check "writes the result next to the source" exists "$work/recording.mp4"
  check "leaves the original in place" exists "$work/recording.mov"
  check "halves the duration" duration_near "$work/recording.mp4" 6
  check "does not use the watch folder" empty_dir "$box/output"
}

test_a_name_that_is_no_file_is_answered_on_the_terminal() {
  local box out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  print -r -- 'not a recording' > "$box/notes.txt"

  # A mistyped command reads as a file name, and only the log used to say what became of it.
  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" doctr "$box/notes.txt" 2>&1)" || code=$?

  check "names what is neither a file nor a command" contains "$out" "'doctr' is not a file or a command"
  check "and the file that is not a video" contains "$out" "notes.txt is not a video"
  # 0 all the same: a right-click entry that exits non-zero puts up an error in Finder.
  check "and exits 0" test "$code" = 0
}

test_one_shot_handles_several_files() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/a.mov"
  cp "$FIXTURES/withaudio.mov" "$work/b.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/a.mov" "$work/b.mov"
  check "optimizes the first" exists "$work/a.mp4"
  check "optimizes the second" exists "$work/b.mp4"
}

test_a_failed_move_into_place_is_reported_not_silent() {
  local box work fakebin tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  # Stands in for mv refusing to put the result in place, for whatever reason the folder has.
  fakebin="$(scratch)"
  print -rl -- '#!/bin/zsh' 'print -u2 "mv: refused by the fake"' 'exit 1' > "$fakebin/mv"
  chmod +x "$fakebin/mv"

  TMPDIR="$tmp" PATH="$fakebin:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov"

  check "does not silently succeed" missing "$work/clip.mp4"
  check "leaves no orphaned temp file behind" test -z "$(ls -A "$tmp")"
  check "names the actual problem" logged "$box" 'could not move clip.mp4'
  check "with mv's own reason beside it" logged "$box" 'mv: refused by the fake'
  check "leaves the source in place" exists "$work/clip.mov"
}

test_one_shot_skips_an_edit_file_selected_alongside_the_video() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"
  print -rl -- 'merge = false' '[recording.mov]' 'cut = 1-2' > "$work/recording.edit.txt"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov" "$work/recording.edit.txt"

  check "shrinks the video" exists "$work/recording.mp4"
  check "does not try to encode the edit file" logged "$box" "skip   recording.edit.txt (not a video)"
  check "so it is never reported as a failed shrink" not_logged "$box" 'FAILED'
}

test_flags_are_answered_not_swallowed() {
  local box out code=0
  box="$(scratch)"
  rmdir "$box" # so we can tell whether --help went on to build the working folders

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --help)"
  check "prints usage" test -n "$out"
  check "and does nothing else" missing "$box"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --nope > /dev/null 2>&1 || code=$?
  check "rejects an unknown flag" test "$code" = 2
}

test_flags_beat_the_config_file() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 28'
  work="$(scratch)"
  cp "$FIXTURES/withaudio.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --speed 4 --no-remove-audio "$work/clip.mov"

  check "takes the speed from the flag" duration_near "$out" 3
  check "names the file after it" exists "$out"
  check "takes the boolean from the flag too" has_audio "$out"
}

test_flags_that_make_no_sense_are_refused() {
  local box code
  box="$(sandbox)"
  settings "$box" 'speed = 2'

  for flag in --crf --nope --no-speed; do
    code=0
    SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
      zsh "$OPTIMIZER" "$flag" > /dev/null 2>&1 || code=$?
    check "refuses $flag" test "$code" = 2
  done
}

test_a_result_is_made_outside_the_folder_it_lands_in() {
  local box work tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  TMPDIR="$tmp" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1

  # A right-click entry cannot rename or delete a file that ffmpeg made on the Desktop, so a half
  # made file beside the recording is one it can neither finish nor clean up. Measured with a probe
  # entry on a real Desktop file; the move in from elsewhere is allowed.
  check "the result lands beside the recording" exists "$work/clip.mp4"
  check "with ffmpeg writing into the temporary folder" logged "$box" "to '$tmp/shrinkit."
  check "and nothing half-made left beside it" test -z "$(ls -A "$work" | grep part)"
  check "nor in the temporary folder" test -z "$(ls -A "$tmp")"
}

test_across_volumes_the_result_is_finished_beside_itself() {
  local box work tmp fakebin
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  # Stands in for a working folder on another drive: the temporary folder reports another device.
  fakebin="$(scratch)"
  print -rl -- '#!/bin/zsh' \
    "[[ \"\$*\" == *'%d'*'$tmp'* ]] && { print 7; exit 0; }" \
    'exec /usr/bin/stat "$@"' > "$fakebin/stat"
  chmod +x "$fakebin/stat"

  TMPDIR="$tmp" PATH="$fakebin:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1

  # A move across volumes is a copy, visible under the final name while it runs; a hidden part
  # beside the result keeps the rename atomic there.
  check "the result lands" exists "$work/clip.mp4"
  check "written beside it, not in the temporary folder" logged "$box" "to '$work/.clip."
  check "and nothing half-made is left" test "$(ls -A "$work" | grep -c part)" = 0
}

test_a_folder_that_will_not_answer_stat_still_gets_the_temporary_folder() {
  local box work tmp fakebin
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"
  # Stands in for a right-click entry that may not look at the Desktop folder itself.
  fakebin="$(scratch)"
  print -rl -- '#!/bin/zsh' \
    "[[ \"\$*\" == *'%d'*'$work'* ]] && exit 1" \
    'exec /usr/bin/stat "$@"' > "$fakebin/stat"
  chmod +x "$fakebin/stat"

  TMPDIR="$tmp" PATH="$fakebin:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1

  # Beside the result is where the entry cannot finish the rename, so a folder it cannot even stat
  # must not send the part there.
  check "the result lands" exists "$work/clip.mp4"
  check "made in the temporary folder" logged "$box" "to '$tmp/shrinkit."
}

# Until the half-written file exists in dir, for up to ten seconds: the moment an encode is under
# way, rather than a guessed number of seconds that can land before ffmpeg has started.
wait_for_part() {
  local _
  for _ in {1..200}; do
    [[ -n "$(ls -A "$1" | grep part)" ]] && return 0
    sleep 0.05
  done
  return 1
}

test_an_interrupted_run_stops_and_cleans_up() {
  local box tmp pid code=0 asked took
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tmp="$(scratch)"
  cp "$FIXTURES/big.mov" "$box/input/a.mov"
  cp "$FIXTURES/big.mov" "$box/input/b.mov"

  TMPDIR="$tmp" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" > /dev/null 2>&1 &
  pid=$!
  wait_for_part "$tmp"
  asked=$SECONDS
  kill -TERM "$pid"
  wait "$pid" || code=$?
  took=$((SECONDS - asked))

  # What brew's teardown does to a running agent. launchd kills it five seconds after asking, so it
  # has to stop well inside that, not when the encode of a 45-second 4K clip is done.
  check "stops with the signal's status" test "$code" = 143
  check "within a couple of seconds" test "$took" -le 2
  check "does not go on to the next file" exists "$box/input/b.mov"
  check "and leaves nothing half-made behind" test -z "$(ls -A "$tmp")"
}

test_an_interrupted_merge_leaves_nothing_behind() {
  local box work tmp pid code=0 asked took
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  # Two shapes, so the takes are re-encoded: joined as they are, they are done before a kill lands.
  recorded_copy "$FIXTURES/big.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/silent.mov" "$work/two.mov" 2026-01-01T10:05:00

  TMPDIR="$tmp" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" merge "$work/one.mov" "$work/two.mov" \
    > /dev/null 2>&1 &
  pid=$!
  wait_for_part "$tmp"
  asked=$SECONDS
  kill -TERM "$pid"
  wait "$pid" || code=$?
  took=$((SECONDS - asked))
  sleep 3 # anything still running would have moved a result in by now

  check "stops with the signal's status" test "$code" = 143
  check "within a couple of seconds" test "$took" -le 2
  check "leaves no half-joined file in the temporary folder" test -z "$(ls -A "$tmp")"
  check "and puts no result in place afterwards" test "$(ls "$work" | grep -c merged)" = 0
}
