# Sourced by tests/run-tests.sh: shrinkit run with merge = true, every block encoded to one format
# and the parts joined by copying their streams.

frame_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2> /dev/null
}

rate_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$1" 2> /dev/null
}

codec_tag_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$1" 2> /dev/null
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

# The parts agree by construction, so the join re-encodes only when copying them fails: here, an
# ffmpeg that cannot join by copying and does everything else as the real one.
test_run_merge_that_has_to_re_encode_the_join_keeps_the_sets_codec() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 a.mov" "codec = hevc"'
  print -rl -- '#!/bin/zsh' '[[ " $* " == *" -f concat "* ]] && exit 1' "exec ${(qq)FFMPEG} \"\$@\"" \
    > "$tools/ffmpeg"
  chmod +x "$tools/ffmpeg"
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  out="$work/1 a-merged.mp4"

  run_file "$box" "$tools" "$work/1 a.edit.txt" > /dev/null

  check "re-encodes the join" logged "$box" 'merged 2 clips into 1 a-merged.mp4 (re-encoded)'
  check "in the set's hevc" test "$(video_codec "$out")" = hevc
  check "tagged hvc1, as the parts are, so QuickTime plays it" test "$(codec_tag_of "$out")" = hvc1
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

# A later block's codec, fps and max_height, from its preset and from its own lines.
test_run_merge_uses_the_first_blocks_codec_fps_and_height() {
  local box tools work out text want
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  mkdir -p "$box/presets"
  print -rl -- 'fps = 60' 'codec = hevc' > "$box/presets/smooth.conf"
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true' 'add "1 small.mov" "fps = 24" "max_height = 180"' \
    'add "2 large.mov" "preset = smooth" "max_height = 360"'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 small.mov"
  cp "$FIXTURES/take-loud.mov" "$work/2 large.mov"
  make_edit "$box" "$tools" "$work/1 small.mov" "$work/2 large.mov"
  out="$work/1 small-merged.mp4"

  text="$(run_file "$box" "$tools" "$work/1 small.edit.txt")"

  for want in \
    "[2/2] 2 large.mov: codec hevc is not used; merge = true encodes every recording in the first one's h264" \
    "[2/2] 2 large.mov: fps 60 is not used; merge = true encodes every recording at the first one's 24 fps" \
    "[2/2] 2 large.mov: max_height 360 is not used; merge = true fits every recording into 320x180"; do
    check "says $want" contains "${text%%$'\n'🎬 \[1/2\]*}" "  ⚠️ $want"$'\n'
    check "and logs it" grep -qF -- "$want" "$box/.logs/optimizer.log"
  done
  check "encodes the set in the first block's codec" test "$(video_codec "$out")" = h264
  check "at its fps" test "$(rate_of "$out")" = 24/1
  check "in the frame its max_height gives the largest recording" test "$(frame_of "$out")" = 320x180
  check "and joins the parts by copying" logged "$box" 'streams copied'
}

test_run_merge_joins_nothing_when_a_block_fails() {
  local box tools work tmp out code=0
  local -a left
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  print -r -- 'not a movie' > "$work/2 broken.mov"
  cp "$FIXTURES/take-blue.mov" "$work/3 c.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 broken.mov" "$work/3 c.mov"

  out="$(TMPDIR="$tmp" run_file "$box" "$tools" "$work/1 a.edit.txt" 2> /dev/null)" || code=$?

  check "names the block it could not shrink" contains "$out" "  ❌ FAILED $work/2 broken.mov"
  check "says nothing is joined, and why" \
    contains "$out" $'\n❌ [join] nothing joined: merge = true joins every recording or none\n'
  check "and logs it" logged "$box" 'nothing joined: merge = true joins every recording or none'
  check "goes no further" not_logged "$box" 'encode 3 c.mov'
  check "leaves no part in the temporary folder" empty_dir "$tmp"
  left=("$work"/*(N))
  check "and nothing beside the recordings but the edit file" test "${#left}" = 4
  check "sums it up" contains "$out" $'\n❌ Nothing was joined.\nNot shrunk: 2 broken.mov'
  check "and exits 1" test "$code" = 1
}

# A block that cannot run is known before the first encode, so nothing is encoded for a set that
# will not be joined.
test_run_merge_encodes_nothing_when_a_block_is_left_out() {
  local box tools work out code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 gone.mov"
  cp "$FIXTURES/take-green.mov" "$work/3 c.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 gone.mov" "$work/3 c.mov"
  rm "$work/2 gone.mov"

  out="$(run_file "$box" "$tools" "$work/1 a.edit.txt" 2> /dev/null)" || code=$?

  check "names the block and why" contains "$out" $'\n⚠️ [2/3] 2 gone.mov: not found beside 1 a.edit.txt\n'
  check "says nothing is joined" contains "$out" $'\n❌ [join] nothing joined: merge = true joins every recording or none\n'
  check "encodes nothing" not_logged "$box" ' encode '
  check "and exits 1" test "$code" = 1
}

test_run_merge_with_one_recording_left_shrinks_it_alone() {
  local box tools work out code=0
  local -a merged
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/clip.mov"
  make_edit "$box" "$tools" "$work/clip.mov"

  out="$(run_file "$box" "$tools" "$work/clip.edit.txt")" || code=$?

  check "shrinks it beside itself" duration_near "$work/clip.mp4" 1
  merged=("$work"/*merged*(N))
  check "joins nothing" test "${#merged}" = 0
  check "says why" contains "$out" $'\n⚠️ merge = true needs two recordings; clip.mov was shrunk on its own\n'
  check "and logs it" logged "$box" 'merge = true needs two recordings; clip.mov was shrunk on its own'
  check "exits 0" test "$code" = 0
}

# As an interrupted merge (tests/07): TERM while the second part is being written.
test_an_interrupted_edit_merge_leaves_nothing_behind() {
  local box tools work tmp pid code=0 asked took _
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 short.mov"
  cp "$FIXTURES/big.mov" "$work/2 long.mov"
  make_edit "$box" "$tools" "$work/1 short.mov" "$work/2 long.mov"

  TMPDIR="$tmp" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" run "$work/1 short.edit.txt" > /dev/null 2>&1 &
  pid=$!
  for _ in {1..400}; do
    grep -q 'done   1 short' "$box/.logs/optimizer.log" 2> /dev/null && break
    sleep 0.05
  done
  wait_for_part "$tmp"
  asked=$SECONDS
  kill -TERM "$pid"
  wait "$pid" || code=$?
  took=$((SECONDS - asked))
  sleep 3 # anything still running would have moved a result in by now

  check "the first part was made before the signal" logged "$box" 'done   1 short'
  check "stops with the signal's status" test "$code" = 143
  check "within a couple of seconds" test "$took" -le 2
  check "leaves no part in the temporary folder" empty_dir "$tmp"
  check "and nothing beside the recordings but the edit file" test "$(ls "$work" | wc -l | tr -d ' ')" = 3
}

test_run_merge_marks_the_join_on_the_terminal() {
  local box tools work out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"

  out="$(run_file "$box" "$tools" "$work/1 a.edit.txt")"

  check "heads the join" contains "$out" $'\n🔗 [join] 2 parts\n'
  check "marks what it made as a result" \
    contains "$out" $'\n  ✅ merged 2 clips into 1 a-merged.mp4 (streams copied)\n'
  check "while the log keeps the words alone" logged "$box" '  merged 2 clips into 1 a-merged.mp4'
}

test_run_merge_puts_the_merged_file_on_the_clipboard_and_in_the_banner() {
  local box tools work out
  local -a copies banners
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify = true' 'copy_to_clipboard = true'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"

  out="$(run_file "$box" "$tools" "$work/1 a.edit.txt")"
  copies=(${(f)"$(grep '^clipboard ' "$tools/osascript.log")"})
  banners=(${(f)"$(grep '^banner ' "$tools/osascript.log")"})

  check "one copy" test "${#copies}" = 1
  check "holding the merged file alone" test "${copies[1]-}" = "clipboard $work/1 a-merged.mp4"
  check "one banner" test "${#banners}" = 1
  check "naming the merged file" contains "${banners[1]-}" "2 recordings shrunk: 1 a-merged.mp4, copied to clipboard"
  check "and the terminal names it" contains "$out" $'\n✅ Done.\n  '"$work/1 a-merged.mp4  ("
  check "alone" test "$(grep -c "^  $work/" <<< "$out")" = 1
}

test_run_merge_says_when_the_join_fails() {
  local box tools work tmp out code=0
  local -a merged banners
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify = true'
  tools="$(scratch)"
  stub_tools "$tools"
  stub_editor "$tools" editor 'set_merge true'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/take-red.mov" "$work/1 a.mov"
  cp "$FIXTURES/take-blue.mov" "$work/2 b.mov"
  make_edit "$box" "$tools" "$work/1 a.mov" "$work/2 b.mov"
  # The joined file cannot be moved in beside the recordings.
  chmod a-w "$work"

  out="$(TMPDIR="$tmp" run_file "$box" "$tools" "$work/1 a.edit.txt" 2> /dev/null)" || code=$?
  chmod u+w "$work"
  banners=(${(f)"$(grep '^banner ' "$tools/osascript.log")"})

  check "says the join failed" contains "$out" \
    $'\n'"  ❌ FAILED join of 2 parts (the reason is in $box/.logs/optimizer.log)"$'\n'
  check "sends the terminal to the log for why" contains "$out" \
    "  ❌ FAILED merge: could not move 1 a-merged.mp4 into $work (the reason is in $box/.logs/optimizer.log)"
  check "while the log keeps its own words" logged "$box" \
    "could not move 1 a-merged.mp4 into .* (the reason is on the line above)"
  check "and does not blame ffmpeg for a move" logged "$box" "FAILED join of 2 parts (the reason is above)$"
  check "sums it up" contains "$out" $'\n\n❌ Nothing was joined.'
  merged=("$work"/*merged*(N))
  check "leaves no merged file" test "${#merged}" = 0
  check "and no part in the temporary folder" empty_dir "$tmp"
  check "posts one banner saying so" test "${banners[*]-}" = "banner Could not merge | 2 recordings shrunk, but nothing was joined | Glass"
  check "and exits 1" test "$code" = 1
}
