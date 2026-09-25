# Sourced by tests/run-tests.sh: shrinkit run with merge = true, every block encoded to one format
# and the parts joined by copying their streams.

frame_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2> /dev/null
}

rate_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$1" 2> /dev/null
}

frames_of() {
  "$FFPROBE" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets \
    -of default=nw=1:nk=1 "$1" 2> /dev/null
}

test_run_merge_joins_the_recordings_in_the_order_of_the_blocks() {
  local box tools work tmp out code=0
  local -a left
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  # The blocks in an order unlike the one shrinkit edit wrote them in, which is when each was shot.
  stub_editor "$tools" editor 'set_merge true' 'drop_blocks' \
    "print -rl -- '' '[green.mov]' '' '[red.mov]' '' '[blue.mov]' >> \"\$file\""
  work="$(scratch)"
  tmp="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/red.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-blue.mov" "$work/blue.mov" 2026-01-01T10:05:00
  recorded_copy "$FIXTURES/take-green.mov" "$work/green.mov" 2026-01-01T10:10:00
  make_edit "$box" "$tools" "$work/red.mov" "$work/blue.mov" "$work/green.mov"
  out="$work/green-merged.mp4"

  TMPDIR="$tmp" run_file "$box" "$tools" "$work/red.edit.txt" > /dev/null || code=$?

  check "writes one file beside the first block's recording" exists "$out"
  check "in the order of the blocks" takes_are "$out" green red blue
  check "as long as the three together" duration_near "$out" 6
  check "by copying the parts" logged "$box" 'streams copied'
  check "leaves no part in the temporary folder" empty_dir "$tmp"
  left=("$work"/*(N))
  check "and nothing beside the recordings but the edit file and the result" test "${#left}" = 5
  check "exits 0" test "$code" = 0
}

# Two sizes of frame, sound taken out of one, missing from another and kept in the third, three crf
# values and two cuts: what a set of takes for one clip looks like. The first block is neither the
# largest nor the one with sound, so the set's frame and sound come from the others.
test_run_merge_encodes_each_recording_once_and_copies_the_join() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'remove_audio = false'
  mkdir -p "$box/presets"
  print -r -- 'crf = 18' > "$box/presets/sharp.conf"
  print -r -- 'crf = 32' > "$box/presets/tiny.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 loud.mov" "remove_audio = true"' \
    'add "2 silent.mov" "preset = tiny" "cut = 0-2"' 'add "3 colored.mov" "preset = sharp" "cut = 3-4"'
  work="$(scratch)"
  cp "$FIXTURES/take-loud.mov" "$work/1 loud.mov"
  cp "$FIXTURES/silent.mov" "$work/2 silent.mov"
  cp "$FIXTURES/colored.mov" "$work/3 colored.mov"
  make_edit "$box" "$tools" "$work/1 loud.mov" "$work/2 silent.mov" "$work/3 colored.mov"
  out="$work/1 loud-merged.mp4"

  run_file "$box" "$tools" "$work/1 loud.edit.txt" > /dev/null

  check "encodes each recording once" test "$(log_count "$box" ' encode ')" = 3
  check "and joins the parts by copying them" logged "$box" 'merged 3 clips into 1 loud-merged.mp4 (streams copied)'
  check "at the largest frame in the set" test "$(frame_of "$out")" = 1920x1080
  check "with one sound track" test "$(audio_tracks "$out")" = 1
  check "as long as the three parts together" roughly_equal "$(duration "$out")" 11.5 0.5
}

test_run_merge_gives_every_part_the_same_parameter_sets() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 a.mov" "crf = 18"' 'add "2 b.mov" "crf = 32"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  out="$work/1 a-merged.mp4"

  run_file "$box" "$tools" "$work/1 a.edit.txt" > /dev/null

  check "joins them by copying" logged "$box" 'streams copied'
  check "with one picture parameter set for both crf values" test "$(pps_values "$out" | wc -l | tr -d ' ')" = 1
}

test_run_merge_copies_a_join_of_hevc_parts() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 a.mov" "codec = hevc" "crf = 18"' \
    'add "2 b.mov" "crf = 32"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  out="$work/1 a-merged.mp4"

  run_file "$box" "$tools" "$work/1 a.edit.txt" > /dev/null

  check "encodes both in the first block's hevc" test "$(video_codec "$out")" = hevc
  check "and joins them by copying" logged "$box" 'streams copied'
  check "as long as the two together" duration_near "$out" 4
}

test_run_merge_fps_zero_keeps_the_first_recordings_rate() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 4'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 a.mov" "fps = 0"'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-red.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  out="$work/1 a-merged.mp4"

  run_file "$box" "$tools" "$work/1 a.edit.txt" > /dev/null

  check "the first recording is 60 fps" test "$(rate_of "$work/1 a.mov")" = 60/1
  check "and so is the merged file" test "$(rate_of "$out")" = 60/1
  # 12 s and 2 s at speed 4 are 3.5 s: 210 frames at 60 fps.
  check "with 60 frames in every second of both parts" roughly_equal "$(frames_of "$out")" 210 3
  check "joined by copying" logged "$box" 'streams copied'
}
