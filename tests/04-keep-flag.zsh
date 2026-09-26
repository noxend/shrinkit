# Sourced by tests/run-tests.sh: the --keep flag.

# --keep is the same edit from the other side, so these read the result as kept footage: in
# colored.mov the red second sits at 3-4 and the green one at 8-9, and which of them survives says
# what was really selected, where a duration on its own would pass for several different answers.
test_keep_flag_keeps_only_the_range_it_was_given() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 3-4 "$work/clip.mov"

  check "leaves just that one second" duration_near "$out" 1
  check "and it is the red second, not another one of the same length" color_at_is 0.5 "$out" fe0000
  check "says a cut was applied" logged "$box" ', cut applied'
}

test_keep_flag_sorts_and_merges_its_ranges() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  # out of order, and the last one inside the one before it
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep 8-9 --keep 3-6 --keep 4-5 "$work/clip.mov"

  check "keeps the merged stretch and the separate one" duration_near "$out" 4
  check "with the green second joined on as the tail" color_at_is 3.5 "$out" 018001
}

test_keep_flag_reaching_the_end_keeps_the_tail() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 9-end "$work/clip.mov"

  check "'end' means the real length here too" duration_near "$out" 3
  check "and neither marker survives in it" no_marker_color_anywhere "$out" 3
}

# Ranges that are all good and together leave nothing to cut is not the same thing as ranges that
# were all rejected: one is the whole recording on purpose, the other is a mistake worth reading
# the log over. Both end up with no cut to apply, so only the done line tells them apart.
test_keep_flag_covering_the_whole_clip_cuts_nothing() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 0-end "$work/clip.mov"

  check "leaves the recording its full length" duration_near "$out" 12
  check "says nothing needed cutting" logged "$box" 'kept the whole clip, nothing to cut'
  check "and does not send anyone to the log over it" not_logged "$box" 'requested but none applied'
}

test_keep_flag_past_the_end_is_refused_as_a_keep() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 20-25 "$work/clip.mov"

  check "keeps the whole recording, the range selected nothing" duration_near "$out" 12
  check "blames a keep, not a cut" logged "$box" "ignoring keep '20-25' from --keep"
  check "and says it was a keep that went unapplied" logged "$box" 'keep requested but none applied'
}

# The gaps between keeps are cut ranges nobody typed, so they never met parse_range's minimum
# length the way a typed range does: two keeps five milliseconds apart came out as a 0.005s cut,
# reported as applied, that removed no frame at all.
test_keep_flag_joins_keeps_too_close_to_cut_between() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep 0-5 --keep 5.005-end "$work/clip.mov"

  check "leaves the recording whole" duration_near "$out" 12
  check "says the two keeps were joined" logged "$box" 'joining the keeps around 5-5.005'
  check "and reports it as kept, not as a cut applied" logged "$box" 'kept the whole clip'
  check "with no cut claimed" not_logged "$box" ', cut applied'
}

test_keep_flag_joins_only_the_gap_that_is_too_short() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep 0-2 --keep 2.005-5 --keep 8-end "$work/clip.mov"

  check "still cuts the 3s gap between the real keeps" duration_near "$out" 9
  check "having joined only the short one" logged "$box" 'joining the keeps around 2-2.005'
}

# Naming both is not a preference to resolve: they describe one edit from opposite sides, and
# picking a winner would cut exactly the footage the other flag asked to keep.
test_keep_and_cut_together_are_refused() {
  local box work code msg
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  code=0
  msg="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut 3-4 --keep 8-9 "$work/clip.mov" 2>&1 > /dev/null)" || code=$?

  check "stops with a usage error" test "$code" = 2
  # The exit code alone cannot tell this apart from --keep never having existed, which also stops
  # at 2: only the message says the two flags were seen and refused together.
  check "saying the two flags describe one edit" \
    test "$msg" = "--cut and --keep are the same edit from opposite sides; use one or the other"
  check "and writes nothing" missing "$work/clip.mp4"
}

test_keep_flag_with_no_file_is_refused() {
  local box code msg
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'keep_original = false'
  cp "$FIXTURES/colored.mov" "$box/input/queued.mov"

  code=0
  msg="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 3-4 2>&1 > /dev/null)" || code=$?

  check "stops with a usage error" test "$code" = 2
  # Same as above: 2 is also what an unknown flag exits with, so the message carries the claim.
  check "asking for the file it should keep from" \
    test "$msg" = "--keep needs the file to keep from, e.g. shrinkit --keep 1:00-2:00 recording.mov"
  check "leaves the queued recording alone" exists "$box/input/queued.mov"
  check "writes nothing" empty_dir "$box/output"
}

test_keep_flag_with_no_range_is_refused() {
  local box work code msg
  box="$(sandbox)"
  settings "$box" 'speed = 1'

  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep > /dev/null 2>&1 || code=$?
  check "stops with a usage error" test "$code" = 2

  # One arm of the parser serves both flags now, so the message has to come back naming the one
  # that was actually typed.
  msg="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 2>&1 > /dev/null)"
  check "naming the flag that was typed" test "$msg" = "--keep needs a range, e.g. --keep 0:32-0:35"

  # The empty value is the mistake that actually happens, a wrapper expanding a variable it never
  # set. Letting it through would shrink the recording without the range that was meant.
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep '' "$work/clip.mov" > /dev/null 2>&1 || code=$?

  check "an empty range is refused too" test "$code" = 2
  check "and without writing an output" missing "$work/clip.mp4"
}
