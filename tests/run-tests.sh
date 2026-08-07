#!/bin/zsh
#
# Test suite for the optimizer. Every test runs the real script against a throwaway folder under
# /tmp, so your own recordings are never touched and the launchd agent is not involved.
#
#   ./tests/run-tests.sh            run everything
#   ./tests/run-tests.sh basic      run only the tests whose name contains "basic"
#
# Sample videos are generated with ffmpeg into tests/fixtures on the first run and reused after
# that. They are not committed: a handful of generated mp4s would outweigh the whole repo.

set -u
setopt extended_glob

TESTS_DIR="${0:A:h}"
REPO_DIR="${TESTS_DIR:h}"
OPTIMIZER="$REPO_DIR/optimize-demo-video.sh"
FIXTURES="$TESTS_DIR/fixtures"

find_tool() {
  local name="$1" candidate
  for candidate in "$(command -v "$name" 2> /dev/null)" "/opt/homebrew/bin/$name" "/usr/local/bin/$name"; do
    [[ -x "$candidate" ]] && {
      print -r -- "$candidate"
      return
    }
  done
}
FFMPEG="$(find_tool ffmpeg)"
FFPROBE="$(find_tool ffprobe)"

[[ -f "$OPTIMIZER" ]] || {
  print "cannot find $OPTIMIZER"
  exit 1
}
[[ -x "$FFMPEG" ]] || {
  print "ffmpeg is required to build the sample videos"
  exit 1
}

FILTER="${1:-}"
typeset -i PASSED=0 FAILED=0
typeset -a FAILURES SANDBOXES

cleanup() {
  local box
  for box in "${SANDBOXES[@]}"; do rm -rf "$box"; done
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------- helpers

ok() {
  print "  ok    $1"
  PASSED=PASSED+1
}
fail() {
  print "  FAIL  $1"
  FAILED=FAILED+1
  FAILURES+=("$CURRENT_TEST: $1")
}

# check "what we expect" <command...>
check() {
  local what="$1"
  shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}

exists() {
  [[ -f "$1" ]]
}
missing() {
  [[ ! -e "$1" ]]
}
empty_dir() {
  [[ -z "$(ls -A "$1" 2> /dev/null)" ]]
}
logged() {
  grep -q -- "$2" "$1/.logs/optimizer.log"
}
log_count() {
  grep -c -- "$2" "$1/.logs/optimizer.log"
}

duration() {
  "$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2> /dev/null
}
video_codec() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2> /dev/null
}
height_of() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$1" 2> /dev/null
}
has_audio() {
  [[ -n "$("$FFPROBE" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2> /dev/null)" ]]
}
no_audio() {
  ! has_audio "$1"
}

# roughly_equal 6.03 6 0.4
roughly_equal() {
  awk -v a="$1" -v b="$2" -v tol="$3" 'BEGIN { exit !(a - b < tol && b - a < tol) }'
}
duration_near() {
  roughly_equal "$(duration "$1")" "$2" 0.4
}
smaller_than() {
  [[ "$(stat -f%z "$1")" -lt "$(stat -f%z "$2")" ]]
}

# A fresh working folder plus the settings the test wants. Everything lives under /tmp.
sandbox() {
  local box
  box="$(mktemp -d)"
  SANDBOXES+=("$box")
  mkdir -p "$box/input" "$box/output" "$box/.processed" "$box/.logs"
  print -r -- "$box"
}

# settings <sandbox> <json body without the braces>
settings() {
  local box="$1" body="$2"
  # notifications are off by default in tests so a run does not spray banners
  print -r -- "{ \"notify\": false, $body }" > "$box/settings.jsonc"
}

# Runs the script under test. DEMO_OPTIMIZER_REPO is blank so the update check stays out of it.
optimize() {
  DEMO_OPTIMIZER_DIR="$1" DEMO_OPTIMIZER_REPO="" zsh "$OPTIMIZER"
}

# --------------------------------------------------------------------- sample videos

# make_fixture <name> <ffmpeg args...>
make_fixture() {
  local name="$1"
  shift
  [[ -f "$FIXTURES/$name" ]] && return
  print "  building $name ..."
  "$FFMPEG" -nostdin -y "$@" "$FIXTURES/$name" > /dev/null 2>&1
}

build_fixtures() {
  mkdir -p "$FIXTURES"
  # 12s of mostly-static 1080p60, which is what a screen recording actually looks like
  make_fixture silent.mov -f lavfi -i "color=c=0x1e1e1e:s=1920x1080:r=60:d=12" \
    -f lavfi -i "testsrc2=s=480x270:r=60:d=12" -filter_complex "[0][1]overlay=60:60" \
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p
  # the same, with a tone, for the audio paths
  make_fixture withaudio.mov -f lavfi -i "color=c=0x1e1e1e:s=1920x1080:r=60:d=12" \
    -f lavfi -i "sine=frequency=440:duration=12" -c:v libx264 -preset medium -crf 20 \
    -pix_fmt yuv420p -c:a aac -shortest
  # 4K, for the downscale test
  make_fixture tall.mov -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=5" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p
  # long 4K, so its encode lasts long enough to drop another file mid-run
  make_fixture big.mov -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=45" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p
}

# --------------------------------------------------------------------- the tests

test_basic_encode() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-2x.mp4"

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
  settings "$box" '"speed": 3, "remove_audio": false, "output_suffix": "-fast", "fps": 0'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-fast.mp4"

  check "honours output_suffix" exists "$out"
  check "honours speed 3 on a 12s clip" duration_near "$out" 4
  check "keeps the audio when asked" has_audio "$out"
}

test_downscale() {
  local box
  box="$(sandbox)"
  settings "$box" '"max_height": 720'
  cp "$FIXTURES/tall.mov" "$box/input/clip.mov"

  optimize "$box"
  check "downscales 2160p to 720p" test "$(height_of "$box/output/clip-2x.mp4")" = 720
}

test_keep_original_false_deletes_the_source() {
  local box
  box="$(sandbox)"
  settings "$box" '"keep_original": false'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "still writes the output" exists "$box/output/clip-2x.mp4"
  check "deletes instead of filing" empty_dir "$box/.processed"
}

test_output_dir_redirect() {
  local box
  box="$(sandbox)"
  settings "$box" "\"output_dir\": \"$box/elsewhere\""
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "writes to the folder we named" exists "$box/elsewhere/clip-2x.mp4"
  check "leaves the default one empty" empty_dir "$box/output"
}

test_skips_work_already_done() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  optimize "$box"

  cp "$FIXTURES/silent.mov" "$box/input/clip.mov" # same name again
  optimize "$box"

  check "says it already has one" logged "$box" 'already has an optimized copy'
  check "does not touch the file" exists "$box/input/clip.mov"
}

test_ignores_things_that_are_not_videos() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  print "not a video" > "$box/input/notes.txt"
  mkdir -p "$box/input/a-folder.mov"

  optimize "$box"
  check "reports an empty queue" logged "$box" 'nothing new to do'
  check "leaves the text file alone" exists "$box/input/notes.txt"
}

test_broken_config_falls_back_to_defaults() {
  local box
  box="$(sandbox)"
  print '{ "speed": 2,' > "$box/settings.jsonc" # truncated on purpose
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "says the config is unreadable" logged "$box" 'not valid JSON'
  check "carries on with the defaults" exists "$box/output/clip-2x.mp4"
}

test_bad_values_are_rejected_one_by_one() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": "abc", "fps": "x", "crf": 99, "codec": "vp9",
                   "remove_audio": "maybe", "output_suffix": ""'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local key
  for key in speed fps crf codec remove_audio output_suffix; do
    check "rejects a bad $key" logged "$box" "ignoring $key="
  done
  check "still encodes on the defaults" exists "$box/output/clip-2x.mp4"
}

test_unknown_settings_are_ignored() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2, "there_is_no_such_setting": "hello"'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "a stray key does no harm" exists "$box/output/clip-2x.mp4"
}

test_comment_characters_inside_values() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 3, "notify_title": "done // ready", "output_suffix": "-2x#a"'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-2x#a.mp4"

  check "a // in a value does not break the parse" exists "$out"
  check "and the rest of the config still lands" duration_near "$out" 4
}

test_lock_keeps_two_runs_apart() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  cp "$FIXTURES/big.mov" "$box/input/clip.mov"

  optimize "$box" &
  sleep 1
  optimize "$box"
  wait

  check "the second run stands down" logged "$box" 'another run has the lock'
  check "the file is encoded once" test "$(log_count "$box" 'encode clip.mov')" = 1
  check "the output survives" exists "$box/output/clip-2x.mp4"
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
  settings "$box" '"speed": 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  plant_lock "$box" "$(dead_pid)"

  optimize "$box"
  check "takes the abandoned lock over" exists "$box/output/clip-2x.mp4"
  check "and leaves none behind" missing "$box/.optimizer.lock"
}

test_a_lock_from_a_live_run_is_left_alone() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
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
  settings "$box" '"speed": 2'
  cp "$FIXTURES/big.mov" "$box/input/first.mov"

  optimize "$box" &
  sleep 6 # while the 4K clip is still encoding
  cp "$FIXTURES/silent.mov" "$box/input/second.mov"
  wait

  check "finishes the first" exists "$box/output/first-2x.mp4"
  check "catches the late arrival too" exists "$box/output/second-2x.mp4"
  check "and empties the queue" empty_dir "$box/input"
}

test_a_broken_file_does_not_wedge_the_queue() {
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  print "this is not really a video" > "$box/input/broken.mov"
  cp "$FIXTURES/silent.mov" "$box/input/good.mov"

  optimize "$box"
  check "reports the failure" logged "$box" 'FAILED broken.mov'
  check "leaves the bad file put" exists "$box/input/broken.mov"
  check "still handles the good one" exists "$box/output/good-2x.mp4"
}

test_one_shot_optimizes_a_file_in_place() {
  local box work
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  # a file living outside the input folder, like something you right-click in Finder
  work="$(mktemp -d)"
  SANDBOXES+=("$work")
  cp "$FIXTURES/silent.mov" "$work/recording.mov"

  DEMO_OPTIMIZER_DIR="$box" DEMO_OPTIMIZER_REPO="" zsh "$OPTIMIZER" "$work/recording.mov"

  check "writes the result next to the source" exists "$work/recording-2x.mp4"
  check "leaves the original in place" exists "$work/recording.mov"
  check "halves the duration" duration_near "$work/recording-2x.mp4" 6
  check "does not use the watch folder" empty_dir "$box/output"
}

test_one_shot_handles_several_files() {
  local box work
  box="$(sandbox)"
  settings "$box" '"speed": 2'
  work="$(mktemp -d)"
  SANDBOXES+=("$work")
  cp "$FIXTURES/silent.mov" "$work/a.mov"
  cp "$FIXTURES/withaudio.mov" "$work/b.mov"

  DEMO_OPTIMIZER_DIR="$box" DEMO_OPTIMIZER_REPO="" zsh "$OPTIMIZER" "$work/a.mov" "$work/b.mov"
  check "optimizes the first" exists "$work/a-2x.mp4"
  check "optimizes the second" exists "$work/b-2x.mp4"
}

test_start_banner_is_logged() {
  # notifications are off in tests, but the start path still runs; make sure it does not error and
  # the finish line is present, which proves notify_start did not abort the run.
  local box
  box="$(sandbox)"
  settings "$box" '"speed": 2, "notify_start": true'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "the run still completes with notify_start on" exists "$box/output/clip-2x.mp4"
}

# --------------------------------------------------------------------- run them

TESTS=(
  test_basic_encode
  test_basic_settings_are_used
  test_downscale
  test_keep_original_false_deletes_the_source
  test_output_dir_redirect
  test_skips_work_already_done
  test_ignores_things_that_are_not_videos
  test_broken_config_falls_back_to_defaults
  test_bad_values_are_rejected_one_by_one
  test_unknown_settings_are_ignored
  test_comment_characters_inside_values
  test_lock_keeps_two_runs_apart
  test_a_lock_from_a_dead_run_is_taken_over
  test_a_lock_from_a_live_run_is_left_alone
  test_picks_up_a_file_dropped_mid_run
  test_a_broken_file_does_not_wedge_the_queue
  test_one_shot_optimizes_a_file_in_place
  test_one_shot_handles_several_files
  test_start_banner_is_logged
)

print "building sample videos in tests/fixtures (first run only)"
build_fixtures
print ""

CURRENT_TEST=""
for CURRENT_TEST in "${TESTS[@]}"; do
  [[ -n "$FILTER" && "$CURRENT_TEST" != *"$FILTER"* ]] && continue
  print "${CURRENT_TEST#test_}"
  "$CURRENT_TEST"
done

print ""
if ((FAILED == 0)); then
  print "$PASSED checks passed"
else
  print "$PASSED passed, $FAILED failed:"
  printf '  %s\n' "${FAILURES[@]}"
fi
exit $((FAILED > 0))
