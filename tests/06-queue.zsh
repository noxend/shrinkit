# Sourced by tests/run-tests.sh: bad settings, the lock, the queue.

test_bad_values_are_rejected_one_by_one() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = abc' 'fps = 100000' 'crf = 99' 'codec = vp9' 'remove_audio = maybe' \
    'keep_days = never'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local key
  for key in speed fps crf codec remove_audio keep_days; do
    check "rejects a bad $key" logged "$box" "ignoring $key="
  done
  check "still encodes on the defaults" exists "$box/output/clip.mp4"
}

test_unknown_settings_are_ignored() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'there_is_no_such_setting = hello'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "a stray key does no harm" exists "$box/output/clip.mp4"
}

test_a_hash_inside_a_value_is_kept() {
  local box
  box="$(sandbox)"
  # only a whole comment line starts with #, so one in the middle of a value is just text
  settings "$box" 'speed = 3' 'notify_sound = Gla#ss'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "keeps the # in the value" not_logged "$box" 'ignoring notify_sound'
  check "and the rest of the config still lands" duration_near "$box/output/clip.mp4" 4
}

test_lock_keeps_two_runs_apart() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/big.mov" "$box/input/clip.mov"

  optimize "$box" &
  sleep 1
  optimize "$box"
  wait

  check "the second run stands down" logged "$box" 'another run has the lock'
  check "the file is encoded once" test "$(log_count "$box" 'encode clip.mov')" = 1
  check "the output survives" exists "$box/output/clip.mp4"
  check "the lock is released" missing "$box/.optimizer.lock"
}

# plant_lock <sandbox> <pid>
plant_lock() {
  mkdir -p "$1/.optimizer.lock"
  print -r -- "$2" > "$1/.optimizer.lock/pid"
}

# A pid that has just exited, so nothing is listening on it any more.
dead_pid() {
  local pid
  (exit 0) &
  pid=$!
  wait $pid 2> /dev/null
  print -r -- "$pid"
}

test_a_lock_from_a_dead_run_is_taken_over() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  plant_lock "$box" "$(dead_pid)"

  optimize "$box"
  check "takes the abandoned lock over" exists "$box/output/clip.mp4"
  check "and leaves none behind" missing "$box/.optimizer.lock"
}

test_a_lock_from_a_live_run_is_left_alone() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  plant_lock "$box" $$ # this shell is very much alive

  optimize "$box"
  check "stands down" logged "$box" 'another run has the lock'
  check "leaves the file where it is" exists "$box/input/clip.mov"
  check "does not delete the other run's lock" exists "$box/.optimizer.lock/pid"
}

test_picks_up_a_file_dropped_mid_run() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/big.mov" "$box/input/first.mov"

  optimize "$box" &
  sleep 6 # while the 4K clip is still encoding
  cp "$FIXTURES/silent.mov" "$box/input/second.mov"
  wait

  check "finishes the first" exists "$box/output/first.mp4"
  check "catches the late arrival too" exists "$box/output/second.mp4"
  check "and empties the queue" empty_dir "$box/input"
}

test_a_recording_that_fails_is_recorded_once() {
  local box id
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  print "this is not really a video" > "$box/input/broken.mov"
  id="$(stat -f '%d:%i:%z' "$box/input/broken.mov")"

  optimize "$box"
  optimize "$box"

  # By what it is, the way a recording that could not be filed away is: a later file under the
  # same name is a different one.
  check "writes it down" grep -qxF -- "$id" "$box/.logs/failed"
  check "once, however often it fails" test "$(grep -cxF -- "$id" "$box/.logs/failed")" = 1
}

test_an_empty_recording_is_logged_as_empty() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  : > "$box/input/clip.mov" # a copy that stopped before it wrote anything

  optimize "$box"

  check "says it is empty" logged "$box" "skip   clip.mov (empty"
  check "rather than still being written" not_logged "$box" "still being written"
}

test_a_broken_file_does_not_wedge_the_queue() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  print "this is not really a video" > "$box/input/broken.mov"
  cp "$FIXTURES/silent.mov" "$box/input/good.mov"

  optimize "$box"
  check "reports the failure" logged "$box" 'FAILED broken.mov'
  check "leaves the bad file put" exists "$box/input/broken.mov"
  check "still handles the good one" exists "$box/output/good.mp4"
}
