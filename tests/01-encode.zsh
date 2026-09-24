# Sourced by tests/run-tests.sh: encoding, settings, archiving, naming.

# --------------------------------------------------------------------- the tests

test_basic_encode() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip.mp4"

  check "produces an output file" exists "$out"
  check "halves a 12s clip at 2x" duration_near "$out" 6
  check "drops the audio track" no_audio "$out"
  check "encodes to h264" test "$(video_codec "$out")" = h264
  check "comes out smaller than the source" smaller_than "$out" "$FIXTURES/withaudio.mov"
  check "files the original away" exists "$box/.processed/clip.mov"
  check "leaves the input folder empty" empty_dir "$box/input"
  check "encodes it exactly once" test "$(log_count "$box" 'encode clip.mov')" = 1
}

test_basic_settings_are_used() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 3' 'remove_audio = false' 'fps = 0'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip.mp4"

  check "honours speed 3 on a 12s clip" duration_near "$out" 4
  check "keeps the audio when asked" has_audio "$out"
}

test_basic_the_output_is_named_after_the_preset() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  preset "$box" chat 'speed = 3'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --preset chat "$work/clip.mov"
  check "names the file after the preset that ran" exists "$work/clip-chat.mp4"

  cp "$FIXTURES/silent.mov" "$box/input/plain.mov"
  optimize "$box"
  check "and leaves a run with no preset unadorned" exists "$box/output/plain.mp4"
}

test_downscale() {
  local box
  box="$(sandbox)"
  settings "$box" 'max_height = 720'
  cp "$FIXTURES/tall.mov" "$box/input/clip.mov"

  optimize "$box"
  check "downscales 2160p to 720p" test "$(height_of "$box/output/clip.mp4")" = 720
}

test_keep_original_false_deletes_the_source() {
  local box
  box="$(sandbox)"
  settings "$box" 'keep_original = false'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "still writes the output" exists "$box/output/clip.mp4"
  check "deletes instead of filing" empty_dir "$box/.processed"
}

test_keep_days_prunes_old_originals() {
  local box
  box="$(sandbox)"
  settings "$box" 'keep_days = 30'
  cp "$FIXTURES/silent.mov" "$box/input/old.mov"
  optimize "$box"
  touch -t 200001010000 "$box/.processed/old.mov"

  cp "$FIXTURES/silent.mov" "$box/input/fresh.mov"
  optimize "$box"

  check "prunes the old original" missing "$box/.processed/old.mov"
  check "keeps the fresh one" exists "$box/.processed/fresh.mov"
  check "says so in the log" logged "$box" 'pruned old.mov'
}

test_keep_days_counts_from_archiving_not_the_recording_date() {
  local box
  box="$(sandbox)"
  settings "$box" 'keep_days = 30'
  cp "$FIXTURES/silent.mov" "$box/input/old-recording.mov"
  touch -t 200506070000 "$box/input/old-recording.mov" # made years ago, dropped in only today

  optimize "$box"
  check "archives it rather than pruning it on day one" exists "$box/.processed/old-recording.mov"
}

test_keep_days_too_large_is_rejected_not_truncated() {
  local box
  box="$(sandbox)"
  # long enough that zsh's own arithmetic would truncate rather than reject a bare comparison
  settings "$box" 'keep_days = 99999999999999999999999999999'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  optimize "$box"
  touch -t 200001010000 "$box/.processed/clip.mov"

  cp "$FIXTURES/silent.mov" "$box/input/second.mov"
  optimize "$box"

  check "rejects it back to the default" logged "$box" "ignoring keep_days="
  check "prunes nothing on the default" exists "$box/.processed/clip.mov"
}

test_keep_days_does_not_claim_a_removal_that_failed() {
  local box
  box="$(sandbox)"
  settings "$box" 'keep_days = 5'
  cp "$FIXTURES/silent.mov" "$box/input/locked.mov"
  optimize "$box"
  touch -t 200001010000 "$box/.processed/locked.mov"
  chflags uchg "$box/.processed/locked.mov"

  cp "$FIXTURES/silent.mov" "$box/input/second.mov"
  optimize "$box"
  chflags nouchg "$box/.processed/locked.mov"

  check "leaves the locked file in place" exists "$box/.processed/locked.mov"
  check "does not claim it was pruned" test "$(log_count "$box" 'pruned locked.mov')" = 0
}

test_keep_days_off_by_default() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/old.mov"
  optimize "$box"
  touch -t 200001010000 "$box/.processed/old.mov"

  cp "$FIXTURES/silent.mov" "$box/input/second.mov"
  optimize "$box"

  check "leaves it alone" exists "$box/.processed/old.mov"
}

test_a_second_recording_with_the_same_name_is_shrunk_too() {
  local box first
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  optimize "$box"
  first="$(shasum "$box/.processed/clip.mov" | cut -d' ' -f1)"

  sleep 1 # a later recording, arriving after the first result was made
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  optimize "$box"

  # It used to sit in input/ for good beside a log line, and the first original was overwritten
  # the moment anything did move a same-named file into .processed/.
  check "does not stay in input/" missing "$box/input/clip.mov"
  check "gets a result of its own" test "$(ls "$box/output" | grep -c '^clip.*\.mp4$')" = 2
  check "keeps the first original as it was" \
    test "$(shasum "$box/.processed/clip.mov" | cut -d' ' -f1)" = "$first"
  check "and keeps the second one beside it" test "$(ls "$box/.processed" | grep -c '^clip.*\.mov$')" = 2
}

test_a_same_named_recording_that_cannot_be_filed_away_is_shrunk_once() {
  local box pid
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  optimize "$box" # an earlier recording's result, output/clip.mp4
  sleep 1
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  chflags uchg "$box/input/clip.mov" # locked in Finder: it cannot be moved to .processed/

  # Its result goes under a free name, and a rescan that looked only at clip.mp4 shrank it again,
  # and again, without end. Bounded here, so a regression fails instead of hanging the suite.
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" > /dev/null 2>&1 &
  pid=$!
  sleep 12
  kill "$pid" 2> /dev/null && pkill -P "$pid" 2> /dev/null
  wait "$pid" 2> /dev/null
  chflags nouchg "$box/input/clip.mov"

  check "is shrunk once" test "$(ls "$box/output" | grep -c '^clip.*\.mp4$')" = 2
  check "and the run ends by itself" test "$(log_count "$box" 'kept   clip.mov in input/')" = 1
  check "saying why it is still in input/" logged "$box" 'could not be moved to .processed/'
}

test_a_recording_arriving_the_same_second_as_an_earlier_result_is_not_taken_for_done() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  optimize "$box"
  # At the start of a second, the earlier result is stamped and the new recording lands, both inside
  # that one whole second; whole-second times cannot tell which came first.
  zmodload zsh/datetime
  while ((10#${${EPOCHREALTIME#*.}[1,2]} > 20)); do sleep 0.02; done
  touch "$box/output/clip.mp4"
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"

  optimize "$box"

  check "is shrunk" missing "$box/input/clip.mov"
}

test_a_recording_that_could_not_be_filed_away_is_not_shrunk_again() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  chmod a-w "$box/.processed" # the original cannot be moved out of input/

  optimize "$box"
  optimize "$box"
  chmod u+w "$box/.processed"

  # Its own result is newer than its arrival, which is how it is told apart from a new recording.
  check "is shrunk once" test "$(ls "$box/output" | grep -c '^clip.*\.mp4$')" = 1
  check "and then left alone" logged "$box" 'already has an optimized copy'
}

test_ignores_things_that_are_not_videos() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  print "not a video" > "$box/input/notes.txt"
  mkdir -p "$box/input/a-folder.mov"

  optimize "$box"
  check "reports an empty queue" logged "$box" 'nothing new to do'
  check "leaves the text file alone" exists "$box/input/notes.txt"
}

# Two right-click entries aimed at one file land on the same output name with no lock between
# them, so the guard is that nothing is ever written at that name until it is complete.
test_the_output_appears_only_once_it_is_finished() {
  local box work out tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/big.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  TMPDIR="$tmp" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1 &
  sleep 2 # the 4K fixture takes several seconds, so this lands mid-encode

  check "nothing sits at the final name yet" missing "$out"
  check "nor anything half-made beside the recording" test "$(ls -A "$work" | grep -c part)" = 0
  check "the half-written file is in the temporary folder" test "$(ls -A "$tmp" | grep -c '\.part\.mp4$')" = 1
  wait

  check "it lands when the encode finishes" exists "$out"
  check "and plays" playable "$out"
  check "leaving no part files behind" test -z "$(ls -A "$tmp")"
}

test_a_broken_line_spoils_only_itself() {
  local box
  box="$(sandbox)"
  settings "$box" 'this line has no equals sign' 'speed = 3' '' '   # an indented comment'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip.mp4"

  check "reads the settings around it" exists "$out"
  check "and applies them" duration_near "$out" 4
}
