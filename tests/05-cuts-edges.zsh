# Sourced by tests/run-tests.sh: ranges at the edges, and cuts on odd footage.

test_cuts_trims_whitespace_around_the_dash() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut '3 - 4' "$work/clip.mov"
  out="$work/clip.mp4"
  check "still cuts it, spaces and all" duration_near "$out" 11
}

test_cuts_do_not_distort_footage_with_a_misleading_frame_rate() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/vfr.mov" "$work/clip.mov"

  # well past the fixture's own ~6.9s, so nothing real is actually removed -- this is purely about
  # whether going through the cuts machinery at all distorts the timing of what survives
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 900-901 "$work/clip.mov"
  out="$work/clip.mp4"
  # setpts=N/FRAME_RATE/TB read this fixture's declared 120fps instead of its real ~0.6fps and
  # compressed it to a fraction of a second; trim+concat rebases on the frames' own timestamps
  check "keeps the real length, not a frame-rate-based guess at it" duration_near "$out" 6.9
}

test_cuts_merge_overlapping_ranges() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-5 --cut 4-6 "$work/clip.mov"
  out="$work/clip.mp4"
  # two overlapping lines merge into one 3-6 cut (3s), not two independently-trimmed stretches
  check "cuts the merged 3s span, not something narrower" duration_near "$out" 9
}

test_cuts_reaching_past_the_real_end_do_not_add_an_empty_trailing_stretch() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  # a CFR fixture does not reproduce this: the empty trailing branch only confuses fps= downstream
  # on footage like vfr.mov's, where FRAME_RATE and the real spacing between frames disagree
  work="$(scratch)"
  cp "$FIXTURES/vfr.mov" "$work/clip.mov"

  # vfr.mov is ~6.9s; nothing survives past 5s
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 5-999 "$work/clip.mov"
  out="$work/clip.mp4"
  check "keeps the first 5s and nothing more" duration_near "$out" 5
}

test_cuts_in_the_middle_keep_both_sides_on_misleading_frame_rate_footage() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  # a single ordinary cut with footage before AND after it, on the fixture that mimics a real
  # ReplayKit recording -- every existing vfr.mov test collapses to one kept stretch and missed a
  # bug that reused one filter label ([vnorm]) for every stretch, silently feeding every stretch
  # after the first the raw un-normalized frames: on this fixture that dropped ~89% of the video
  work="$(scratch)"
  cp "$FIXTURES/vfr.mov" "$work/clip.mov"

  # vfr.mov is ~6.9s; keeps [0,1) and [2,end)
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 1-2 "$work/clip.mov"
  out="$work/clip.mp4"
  check "keeps roughly all of both sides of the cut" duration_near "$out" 5.9
}

test_cuts_still_respect_the_fps_cap_once_speed_changes_the_frame_rate() {
  local box work out frames rate
  box="$(sandbox)"
  settings "$box" 'speed = 3' 'fps = 20'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"
  out="$work/clip.mp4"
  # cutting keeps a fixed frame rate before speeding up, so speed x3 on that is real content moving
  # 3x faster -- nothing re-applied the fps cap afterward, so this used to land near 60fps (native,
  # doubled by an ffmpeg default) rather than the configured 20
  rate="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$out")"
  frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$out")"
  check "declares the configured 20fps, not something speed-inflated" test "$rate" = "20/1"
  check "and the frame count matches it" roughly_equal "$frames" 73 5
}

test_cuts_accept_a_range_that_is_exactly_the_minimum_length() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/vfr.mov" "$work/clip.mov"

  # 6.1 - 6.0 lands a hair under 0.1 in IEEE-754 double subtraction; a plain, deliberately-typed
  # 0.1s cut should not be silently discarded over that
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 6.0-6.1 "$work/clip.mov"
  out="$work/clip.mp4"
  check "accepts the exact-0.1s range" logged "$box" ', cut applied'
  check "does not treat it as too short" not_logged "$box" 'too short'
}

test_mark_cuts_with_no_files_is_refused() {
  local code=0
  zsh "$OPTIMIZER" mark-cuts > /dev/null 2>&1 || code=$?
  check "stops with a usage error" test "$code" = 2
}
