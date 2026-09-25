# Sourced by tests/run-tests.sh: cutting ranges out with --cut, and a .cuts file that is not read.

test_cuts_remove_the_marked_ranges() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 --cut 8-9 "$work/clip.mov"
  out="$work/clip.mp4"

  check "produces the output" exists "$out"
  check "drops both ranges, one per --cut (12s -> ~10s)" duration_near "$out" 10
  check "no red or green frame survives anywhere" no_marker_color_anywhere "$out" 10
  check "encodes it" logged "$box" 'encode clip.mov'
  check "says so in the log" logged "$box" ', cut)'
}

test_cuts_accept_the_mm_ss_format() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 0:03-0:04 --cut 0:08-0:09 "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts the same two seconds either way" duration_near "$out" 10
}

test_cuts_keep_kept_audio_in_sync() {
  local box work out video_len audio_len
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'remove_audio = false'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 --cut 8-9 "$work/clip.mov"
  out="$work/clip.mp4"
  video_len="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$out")"
  audio_len="$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=duration -of default=nw=1:nk=1 "$out")"
  check "keeps the audio" has_audio "$out"
  check "video and audio land within half a second of each other" roughly_equal "$video_len" "$audio_len" 0.5
}

test_cuts_bad_range_spoils_only_itself() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut not-a-range --cut 3-4 "$work/clip.mov"
  out="$work/clip.mp4"
  check "still applies the good range" duration_near "$out" 11
  # Names the flag, not just the bad range: every origin shares this rejection code and passes its
  # own phrase in, so an assertion stopping at the range would pass whichever origin it named.
  check "logs the bad one against the flag it came from" \
    logged "$box" "ignoring cut 'not-a-range' from --cut"
}

test_cuts_reject_a_range_under_one_frame() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3.001-3.015 "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts nothing, the range is under one frame" duration_near "$out" 12
  check "says why in the log" logged "$box" "too short to reliably cut"
  check "does not claim a cut happened" not_logged "$box" ', cut)'
}

# A range starting at or past the clip's real length cuts nothing (ffmpeg's own trim= just clamps
# to the real end), and must be reported as such rather than as an applied cut -- otherwise a
# mistyped or misjudged timestamp ships the source untouched while claiming it was redacted.
test_cuts_reject_a_range_past_the_real_end() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 15-16 "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts nothing, the range starts past the clip's end" duration_near "$out" 12
  check "says why in the log" logged "$box" "starts at or after the clip's real length"
  check "does not claim a cut happened" logged "$box" "cut requested but none applied"
}

test_cuts_that_remove_everything_fail_instead_of_destroying_the_original() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 0-12 "$work/clip.mov"
  check "does not write a broken output" missing "$work/clip.mp4"
  check "leaves the original in place" exists "$work/clip.mov"
  check "logs it as a failure, not a success" logged "$box" "FAILED $work/clip.mov"
}

test_cuts_zero_cuts_from_the_start() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 0-3 "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts the first 3 seconds" duration_near "$out" 9
}

test_cuts_end_is_not_case_sensitive() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 9-END "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts from 9s to the end" duration_near "$out" 9
}

# A leading blank ("-0:20") is deliberately not a shorthand for "from the start": it reads exactly
# like a negative number to anyone who has not read this file's own rules. "0-0:20" already does the
# same job unambiguously, so a bare leading dash is left to fail like any other malformed range.
test_cuts_leading_dash_is_not_a_shorthand() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut -3 "$work/clip.mov"
  out="$work/clip.mp4"
  check "cuts nothing, not read as -0:03 from the start" duration_near "$out" 12
  check "logs it as malformed" logged "$box" "ignoring cut '-3'"
}

test_cuts_reject_a_malformed_end_like_a_stray_dash() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4-4 "$work/clip.mov"
  out="$work/clip.mp4"
  check "does not mistake the stray dash for a number" duration_near "$out" 12
  check "logs the whole malformed range" logged "$box" "ignoring cut '3-4-4'"
}

test_cuts_long_bad_range_is_truncated_in_the_log() {
  local box work i nums long_range
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  nums=()
  for i in {0..499}; do nums+=("$i"); done
  long_range="${(j:-:)nums}"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut "$long_range" "$work/clip.mov"
  check "logs it cut short" logged "$box" "ignoring cut '${long_range:0:80}'"
  check "not the whole thing" not_logged "$box" "$long_range"
}

test_cuts_note_says_applied_when_a_cut_took() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"
  check "says so on the done line" logged "$box" 'done   clip.mp4.*, cut applied'
}

test_cuts_note_is_silent_when_no_cut_is_asked() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov"
  check "keeps the full length" duration_near "$work/clip.mp4" 12
  check "no cuts mentioned on a plain shrink" not_logged "$box" 'cut applied'
  check "and no false 'none applied' either" not_logged "$box" 'none applied'
}

test_cuts_note_warns_when_every_range_was_rejected() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut garbage "$work/clip.mov"
  check "says a cut was asked for but nothing came of it" \
    logged "$box" 'done   clip.mp4.*, cut requested but none applied'
}

# The sidecar went in 4.0, the edit file holds cuts now. One left on disk is neither read nor moved.
test_a_cuts_file_beside_a_recording_is_not_read() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '3-4' > "$work/clip.mov.cuts"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov"
  out="$work/clip.mp4"

  check "shrinks the whole recording" duration_near "$out" 12
  check "encodes it without a cut" not_logged "$box" ', cut)'
  check "leaves the file as it was" test "$(< "$work/clip.mov.cuts")" = '3-4'
}

test_a_cuts_file_in_input_is_left_there_when_its_recording_is_filed_away_or_deleted() {
  local box keep
  for keep in true false; do
    box="$(sandbox)"
    settings "$box" 'speed = 2' "keep_original = $keep"
    cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
    print -r -- '3-4' > "$box/input/clip.mov.cuts"

    optimize "$box"

    check "keep_original = $keep: shrinks the recording" exists "$box/output/clip.mp4"
    check "keep_original = $keep: the recording leaves input/" missing "$box/input/clip.mov"
    check "keep_original = $keep: the .cuts file stays in input/" exists "$box/input/clip.mov.cuts"
    check "keep_original = $keep: and does not go to .processed/" missing "$box/.processed/clip.mov.cuts"
  done
}

# A cut written there to take something out ships uncut now, so the run says so rather than
# leaving it to be found in the result.
test_a_cuts_file_beside_a_recording_is_named_as_no_longer_read() {
  local box work fakebin
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify = true' 'notify_start = false'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '3-4' > "$work/clip.mov.cuts"
  # Banners go through osascript; this one writes down what it was asked to show instead.
  fakebin="$(scratch)"
  print -rl -- '#!/bin/zsh' "print -r -- \"\$*\" >> ${(qq)fakebin}/banners" > "$fakebin/osascript"
  chmod +x "$fakebin/osascript"

  PATH="$fakebin:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov"

  check "says so in the log" logged "$box" 'clip.mov.cuts is no longer read; cut with shrinkit: edit or --cut'
  check "and in one banner" test "$(grep -c 'clip.mov.cuts is no longer read' "$fakebin/banners")" = 1
}
