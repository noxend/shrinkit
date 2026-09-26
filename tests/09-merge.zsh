# Sourced by tests/run-tests.sh: merging recordings.

# --------------------------------------------------------------------- merging

run_merge() {
  local box="$1"
  shift
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" merge "$@"
}

# A copy of a take that says when it was recorded. merge reads creation_time first, so a test about
# ordering has to state the order rather than inherit whatever the checkout's mtimes happen to be.
# recorded_copy <fixture> <dest> <YYYY-MM-DDTHH:MM:SS>
recorded_copy() {
  "$FFMPEG" -nostdin -y -i "$1" -map 0 -c copy -metadata creation_time="$3Z" "$2" > /dev/null 2>&1
}

audio_tracks() {
  "$FFPROBE" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2> /dev/null \
    | grep -c .
}

# The colour in the middle of the frame, where the takes are flat and nothing overlays them.
colour_at() {
  local hex r g b
  hex="$("$FFMPEG" -y -ss "$1" -i "$2" -frames:v 1 -vf "crop=4:4:in_w/2:in_h/2" \
    -f rawvideo -pix_fmt rgb24 -s 1x1 - 2> /dev/null | xxd -p)"
  [[ "$hex" =~ ^[0-9a-f]{6}$ ]] || {
    print -r -- "unreadable"
    return
  }
  # Which channel leads, not the exact value: yuv420p round-tripping moves every channel by a few
  # counts, and by more once a take has been re-encoded.
  r=$((16#${hex[1,2]}))
  g=$((16#${hex[3,4]}))
  b=$((16#${hex[5,6]}))
  if ((r > g && r > b)); then
    print -r -- red
  elif ((g > r && g > b)); then
    print -r -- green
  elif ((b > r && b > g)); then
    print -r -- blue
  else
    print -r -- grey
  fi
}

# takes_are <file> <colour>...: every take is 2s, so the middle of the Nth is at 2N-1 seconds.
takes_are() {
  local file="$1" want found i=1
  shift
  for want in "$@"; do
    found="$(colour_at $((2 * i - 1)) "$file")"
    [[ "$found" == "$want" ]] || {
      print "    take $i is $found, expected $want"
      return 1
    }
    i=$((i + 1))
  done
}

test_merge_joins_the_takes_into_one_file() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/two.mov" 2026-01-01T10:05:00

  run_merge "$box" "$work/one.mov" "$work/two.mov"

  check "writes one file beside the first take" exists "$work/one-merged.mov"
  check "as long as the takes together, not shrunk by speed = 2" \
    duration_near "$work/one-merged.mov" 4
  check "in the order they were recorded" takes_are "$work/one-merged.mov" red blue
  check "leaves the first source where it was" exists "$work/one.mov"
  check "leaves the second source where it was" exists "$work/two.mov"
  check "joins the streams rather than re-encoding them" logged "$box" 'streams copied'
}

test_merge_writes_its_temp_file_outside_the_takes_folder() {
  local box work tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/two.mov" 2026-01-01T10:05:00

  TMPDIR="$tmp" run_merge "$box" "$work/one.mov" "$work/two.mov"

  # The same Desktop rule as a shrink: the join is built elsewhere and moved in finished.
  check "joins them" exists "$work/one-merged.mov"
  check "with ffmpeg writing into the temporary folder" logged "$box" "to '$tmp/shrinkit."
  check "and nothing half-made left beside the takes" test -z "$(ls -A "$work" | grep part)"
  check "nor in the temporary folder" test -z "$(ls -A "$tmp")"
}

test_merge_orders_by_when_each_take_was_recorded() {
  local box work
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  # Handed over in alphabetical order, recorded in the opposite one.
  recorded_copy "$FIXTURES/take-red.mov" "$work/a-second.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/z-first.mov" 2026-01-01T10:00:00

  run_merge "$box" "$work/a-second.mov" "$work/z-first.mov"

  check "names the result after the take that comes first" exists "$work/z-first-merged.mov"
  check "and joins them in the order they were shot" takes_are "$work/z-first-merged.mov" blue red
}

test_merge_a_number_at_the_front_beats_the_recording_time() {
  local box work
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-green.mov" "$work/2 later.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-red.mov" "$work/1 first.mov" 2026-01-01T10:05:00

  run_merge "$box" "$work/2 later.mov" "$work/1 first.mov"

  check "names the result after the take numbered 1" exists "$work/1 first-merged.mov"
  check "and the numbers decide the order" takes_are "$work/1 first-merged.mov" red green
}

test_merge_numbered_takes_come_before_unnumbered_ones() {
  local box work
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-blue.mov" "$work/intro.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-red.mov" "$work/1 bug.mov" 2026-01-01T10:05:00

  run_merge "$box" "$work/intro.mov" "$work/1 bug.mov"

  check "puts the numbered take first" takes_are "$work/1 bug-merged.mov" red blue
}

test_merge_a_date_at_the_front_of_a_name_is_not_a_take_number() {
  local box work
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  # Both takes are unnumbered, so recording time alone decides. A rule that took "12" or "2026" for
  # a take number would pull the dated name in front of the take that was actually shot first, and
  # name the result after it; pairing a date against a numbered take would not show that, since the
  # numbered take sorts first either way.
  recorded_copy "$FIXTURES/take-green.mov" "$work/12-01-2026 demo.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-red.mov" "$work/intro.mov" 2026-01-01T10:00:00

  run_merge "$box" "$work/12-01-2026 demo.mov" "$work/intro.mov"

  check "names the result after the take shot first" exists "$work/intro-merged.mov"
  check "reads a day-first date as a name, not as take 12" takes_are "$work/intro-merged.mov" red green

  recorded_copy "$FIXTURES/take-green.mov" "$work/2026 review.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-red.mov" "$work/notes.mov" 2026-01-01T10:00:00

  run_merge "$box" "$work/2026 review.mov" "$work/notes.mov"

  check "and reads a bare year as a name, not as take 2026" takes_are "$work/notes-merged.mov" red green
}

test_merge_keeps_every_sound_track_of_a_copied_take() {
  local box work out
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-two-tracks.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-two-tracks.mov" "$work/two.mov" 2026-01-01T10:05:00
  out="$work/one-merged.mov"

  check "the takes really do carry two tracks each" test "$(audio_tracks "$work/one.mov")" = 2
  run_merge "$box" "$work/one.mov" "$work/two.mov"

  check "joins them without re-encoding" logged "$box" 'streams copied'
  check "keeps both sound tracks" test "$(audio_tracks "$out")" = 2
  check "and comes out as long as the two takes" duration_near "$out" 4
}

test_merge_handles_a_quote_in_the_name() {
  local box work out
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  # The concat list quotes each path in single quotes, so a quote inside one ends the path early.
  recorded_copy "$FIXTURES/take-red.mov" "$work/sasha's take.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/second take.mov" 2026-01-01T10:05:00
  out="$work/sasha's take-merged.mov"

  run_merge "$box" "$work/sasha's take.mov" "$work/second take.mov"

  check "writes the joined file next to a name with a quote in it" exists "$out"
  check "and joins the takes in order" takes_are "$out" red blue
}

test_merge_re_encodes_takes_that_do_not_match() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'codec = hevc'
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-loud.mov" "$work/two.mov" 2026-01-01T10:05:00
  out="$work/one-merged.mp4"

  run_merge "$box" "$work/one.mov" "$work/two.mov"

  check "says why it had to re-encode" logged "$box" 'differ in size, codec, encoder settings or sound'
  check "still produces one file" exists "$out"
  check "that plays" playable "$out"
  check "as long as the takes together" duration_near "$out" 4
  check "at the larger of the two sizes" test "$(height_of "$out")" = 360
  check "with the sound the other take had" has_audio "$out"
  check "and keeps the order" takes_are "$out" red grey
  check "in h264, whatever codec settings.conf names" test "$(video_codec "$out")" = h264
}

# Two results shrinkit made at different crf: the same codec, size and pixel format, and picture
# parameter sets that differ, which a copy would put under the first result's header.
test_merge_re_encodes_takes_whose_parameter_sets_differ() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 red.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 blue.mov"
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --crf 18 "$work/1 red.mov"
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --crf 32 "$work/2 blue.mov"
  out="$work/1 red-merged.mp4"

  run_merge "$box" "$work/1 red.mp4" "$work/2 blue.mp4"

  check "says why it had to re-encode" logged "$box" 'differ in size, codec, encoder settings or sound'
  check "rather than copying the streams" not_logged "$box" 'streams copied'
  check "into one picture parameter set" test "$(pps_values "$out" | wc -l | tr -d ' ')" = 1
  check "and keeps the order" takes_are "$out" red blue
}

test_merge_says_when_the_result_cannot_be_moved_in() {
  local box work tmp code=0
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  tmp="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/two.mov" 2026-01-01T10:05:00
  chmod a-w "$work"

  TMPDIR="$tmp" run_merge "$box" "$work/one.mov" "$work/two.mov" 2> /dev/null || code=$?
  chmod u+w "$work"

  check "the move is what failed" logged "$box" 'could not move one-merged.mov'
  check "says the merge failed, without blaming ffmpeg" logged "$box" \
    'FAILED merge of 2 clips (the reason is above)$'
  check "and exits 1" test "$code" = 1
}

test_merge_needs_at_least_two_videos() {
  local box work code
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/one.mov"

  code=0
  run_merge "$box" "$work/one.mov" > /dev/null 2>&1 || code=$?
  check "refuses a single file" test "$code" = 2
  check "and writes nothing" missing "$work/one-merged.mov"

  code=0
  run_merge "$box" > /dev/null 2>&1 || code=$?
  check "refuses an empty selection too" test "$code" = 2
}

test_merge_skips_a_file_that_is_not_a_video() {
  local box work code
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/one.mov"
  print -r -- "one.mov is the good one" > "$work/notes.txt"

  code=0
  run_merge "$box" "$work/one.mov" "$work/notes.txt" > /dev/null 2>&1 || code=$?
  check "does not count it towards the two" test "$code" = 2
  check "and says which file it skipped" logged "$box" 'skip   notes.txt (not a video)'
}

test_merge_does_not_overwrite_an_earlier_merge() {
  local box work
  local -a extra
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/two.mov" 2026-01-01T10:05:00

  run_merge "$box" "$work/one.mov" "$work/two.mov"
  run_merge "$box" "$work/one.mov" "$work/two.mov"

  extra=("$work"/one-merged-*.mov(N))
  check "keeps the first result" exists "$work/one-merged.mov"
  check "and writes the second under a name of its own" test "${#extra}" = 1
}

# SPEC.md, At most 10 recordings: a re-encoding merge decodes every clip at once.
test_merge_takes_at_most_ten_recordings() {
  local box work out code=0 i
  local -a clips made
  box="$(sandbox)"
  settings "$box"
  work="$(scratch)"
  for i in {1..11}; do
    cp "$FIXTURES/take-red.mov" "$work/$i take.mov"
    clips+=("$work/$i take.mov")
  done

  out="$(run_merge "$box" "${clips[@]}" 2>&1)" || code=$?
  made=("$work"/*merged*(N))

  check "refuses 11" test "$code" = 2
  check "saying why" contains "$out" "shrinkit: merge takes up to 10 recordings at a time; 11 were selected"
  check "and in the log" logged "$box" "shrinkit: merge takes up to 10 recordings at a time; 11 were selected"
  check "joining nothing" test "${#made}" = 0
  check "and writing nothing beside them" test "$(ls "$work" | wc -l | tr -d ' ')" = 11

  code=0
  run_merge "$box" "${clips[@]:0:10}" > /dev/null 2>&1 || code=$?
  check "takes 10" test "$code" = 0
  check "and joins them" duration_near "$work/1 take-merged.mov" 20
}

test_the_merge_entry_says_it_takes_at_most_ten_recordings() {
  local box tools work code=0 i
  local -a clips
  box="$(installed_box)"
  print -r -- 'notify_sound = Ping' >> "$box/work/settings.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  work="$(scratch)"
  for i in {1..11}; do
    cp "$FIXTURES/take-red.mov" "$work/$i take.mov"
    clips+=("$work/$i take.mov")
  done

  run_entry "$box" "$tools" merge "${clips[@]}" 2> /dev/null || code=$?

  check "in a banner, since nothing else it says is seen" test "$(< "$tools/osascript.log")" = \
    "banner shrinkit | shrinkit: merge takes up to 10 recordings at a time; 11 were selected | Ping"
  check "and exits 2" test "$code" = 2
}
