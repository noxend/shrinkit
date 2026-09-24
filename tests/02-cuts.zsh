# Sourced by tests/run-tests.sh: cutting from a .cuts sidecar.

test_cuts_remove_the_marked_ranges() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '3-4' '8-9' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"

  check "produces the output" exists "$out"
  check "drops roughly the cut two seconds (12s -> ~10s)" duration_near "$out" 10
  check "no red or green frame survives anywhere" no_marker_color_anywhere "$out" 10
  check "encodes it" logged "$box" 'encode clip.mov'
  check "says so in the log" logged "$box" ', cut)'
}

test_cuts_accept_the_mm_ss_format() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '0:03-0:04' '0:08-0:09' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts the same two seconds either way" duration_near "$out" 10
}

test_cuts_keep_kept_audio_in_sync() {
  local box out video_len audio_len
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'remove_audio = false'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '3-4' '8-9' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  video_len="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$out")"
  audio_len="$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=duration -of default=nw=1:nk=1 "$out")"
  check "keeps the audio" has_audio "$out"
  check "video and audio land within half a second of each other" roughly_equal "$video_len" "$audio_len" 0.5
}

test_cuts_are_skipped_with_no_sidecar_file() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"

  optimize "$box"
  check "keeps the full length" duration_near "$box/output/clip.mp4" 12
}

test_cuts_bad_line_spoils_only_itself() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- 'not-a-range' '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "still applies the good range" duration_near "$out" 11
  # Names the sidecar, not just the bad range: the flag path shares this rejection code and passes
  # its own origin phrase in, so an assertion stopping at the range would pass either way round.
  check "logs the bad one against the file it came from" \
    logged "$box" "ignoring cut 'not-a-range' in clip.mov.cuts"
}

test_cuts_sidecar_is_archived_with_the_original() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "archives the source" exists "$box/.processed/clip.mov"
  check "archives the sidecar with it" exists "$box/.processed/clip.mov.cuts"
}

test_cuts_sidecar_is_deleted_with_the_original() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'keep_original = false'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "deletes the source" missing "$box/input/clip.mov"
  check "deletes the sidecar with it" missing "$box/input/clip.mov.cuts"
}

# A failed archive (locked/permission-denied source) must not let the sidecar move on its own --
# otherwise the sidecar ends up archived while the video it belongs to is still stuck in input/.
test_a_failed_archive_does_not_orphan_the_cuts_sidecar() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"
  chflags uchg "$box/input/clip.mov"

  optimize "$box"
  chflags nouchg "$box/input/clip.mov"

  check "leaves the source in place" exists "$box/input/clip.mov"
  check "leaves the sidecar with it, not archived alone" exists "$box/input/clip.mov.cuts"
  check "does not archive either one" missing "$box/.processed/clip.mov"
}

test_cuts_reject_a_range_under_one_frame() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3.001-3.015' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts nothing, the range is under one frame" duration_near "$out" 12
  check "says why in the log" logged "$box" "too short to reliably cut"
  check "does not claim a cut happened" not_logged "$box" ', cut)'
}

# A range starting at or past the clip's real length cuts nothing (ffmpeg's own trim= just clamps
# to the real end), and must be reported as such rather than as an applied cut -- otherwise a
# mistyped or misjudged timestamp ships the source untouched while claiming it was redacted.
test_cuts_reject_a_range_past_the_real_end() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '15-16' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts nothing, the range starts past the clip's end" duration_near "$out" 12
  check "says why in the log" logged "$box" "starts at or after the clip's real length"
  check "does not claim a cut happened" logged "$box" "cut requested but none applied"
}

test_cuts_that_remove_everything_fail_instead_of_destroying_the_original() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '0-12' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "does not write a broken output" missing "$box/output/clip.mp4"
  check "leaves the original in place" exists "$box/input/clip.mov"
  check "logs it as a failure, not a success" logged "$box" 'FAILED clip.mov'
}

test_cuts_zero_cuts_from_the_start() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '0-3' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts the first 3 seconds" duration_near "$out" 9
}

test_cuts_end_reaches_the_real_length() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '9-end' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts from 9s to the end" duration_near "$out" 9
}

test_cuts_end_is_not_case_sensitive() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '9-END' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts from 9s to the end" duration_near "$out" 9
}

# A leading blank ("-0:20") is deliberately not a shorthand for "from the start": it reads exactly
# like a negative number to anyone who has not read this file's own rules. "0-0:20" already does the
# same job unambiguously, so a bare leading dash is left to fail like any other malformed line.
test_cuts_leading_dash_is_not_a_shorthand() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '-3' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts nothing, not read as -0:03 from the start" duration_near "$out" 12
  check "logs it as malformed" logged "$box" "ignoring cut '-3'"
}

test_cuts_reject_a_malformed_end_like_a_stray_dash() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "does not mistake the stray dash for a number" duration_near "$out" 12
  check "logs the whole malformed line" logged "$box" "ignoring cut '3-4-4'"
}

test_cuts_unreadable_sidecar_is_logged_and_skipped() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"
  chmod 000 "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "says it could not read the sidecar" logged "$box" 'cannot read clip.mov.cuts'
  check "carries on rather than leaving it unprocessed" duration_near "$out" 12
}

test_cuts_without_a_trailing_newline_still_applies() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  printf '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "cuts the range on the unterminated last line" duration_near "$out" 11
}

test_cuts_long_bad_line_is_truncated_in_the_log() {
  local box i nums long_line
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  nums=()
  for i in {0..499}; do nums+=("$i"); done
  long_line="${(j:-:)nums}"
  print -r -- "$long_line" > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "logs the truncated line" logged "$box" "ignoring cut '${long_line:0:80}'"
  check "not the whole thing" not_logged "$box" "$long_line"
}

test_cuts_note_says_applied_when_a_cut_took() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "says so on the done line" logged "$box" 'done   clip.mp4.*, cut applied'
}

test_cuts_note_is_silent_with_no_sidecar() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"

  optimize "$box"
  check "no cuts mentioned on a plain shrink" not_logged "$box" 'cut applied'
  check "and no false 'none applied' either" not_logged "$box" 'none applied'
}

test_cuts_note_warns_when_every_line_was_rejected() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- 'garbage' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "says the sidecar was there but nothing came of it" \
    logged "$box" 'done   clip.mp4.*, cut requested but none applied'
}

test_cuts_near_miss_filename_is_warned_about() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.cuts" # missing the .mov, so it never matches clip.mov.cuts

  optimize "$box"
  check "names the stray file it found" logged "$box" "found 'clip.cuts'"
  check "and the name it actually expected" logged "$box" "expected 'clip.mov.cuts'"
  check "still shrinks the file" exists "$box/output/clip.mp4"
}

# A second, unrelated recording that merely shares the first few characters of its name (Finder's
# own "clip.mov" / "clip 2.mov" duplicate naming is the everyday way to end up with this) must not
# be mistaken for a typo'd sidecar meant for this one.
test_cuts_unrelated_file_sharing_a_name_prefix_is_not_a_near_miss() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip 2.mov.cuts" # belongs to a different recording entirely

  optimize "$box"
  check "does not warn about the unrelated file" not_logged "$box" "found 'clip 2.mov.cuts'"
  check "shrinks the file untouched, no cuts requested" duration_near "$box/output/clip.mp4" 12
}
