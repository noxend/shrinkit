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
OPTIMIZER="$REPO_DIR/shrinkit.sh"
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
typeset -a FAILURES

# Every sandbox lives under one root, so cleanup is one rm -rf instead of tracking each path
# individually -- which used to need a file, not an array, since a sandbox is usually created
# inside a $(...) capture, a subshell an array append would never escape.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

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
contains() {
  [[ "$1" == *"$2"* ]]
}
lacks() {
  [[ "$1" != *"$2"* ]]
}
logged() {
  grep -q -- "$2" "$1/.logs/optimizer.log"
}
not_logged() {
  ! grep -q -- "$2" "$1/.logs/optimizer.log"
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
playable() {
  "$FFPROBE" -v error "$1" > /dev/null 2>&1
}

# color_at <seconds> <file>, a corner untouched by colored.mov's moving overlay
color_at() {
  "$FFMPEG" -y -ss "$1" -i "$2" -frames:v 1 -vf "crop=4:4:600:330" \
    -f rawvideo -pix_fmt rgb24 -s 1x1 - 2> /dev/null | xxd -p
}
# color_at_is <seconds> <file> <hex>: the keep tests care which footage survived, which a duration
# on its own cannot tell apart from a stretch of the same length somewhere else.
color_at_is() {
  [[ "$(color_at "$1" "$2")" == "$3" ]]
}
no_marker_color_anywhere() {
  local file="$1" dur="$2" t
  for t in $(seq 0 0.5 "$dur"); do
    # fe0000/018001, not the nominal ff0000/008000: yuv420p round-tripping shifts every channel by a
    # few counts, and ffmpeg's named "green" is X11 dark-green (0,128,0) to begin with.
    case "$(color_at "$t" "$file")" in
      fe0000 | 018001) return 1 ;;
    esac
  done
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

# A temp dir under TMPROOT, so it is cleaned up along with everything else.
scratch() {
  mktemp -d "$TMPROOT/tmp.XXXXXX"
}

# A fresh working folder plus the settings the test wants.
sandbox() {
  local box
  box="$(scratch)"
  mkdir -p "$box/input" "$box/output" "$box/.processed" "$box/.logs"
  print -r -- "$box"
}

# settings <sandbox> <line...>
settings() {
  local box="$1"
  shift
  # notifications are off by default in tests so a run does not spray banners
  print -rl -- "notify = false" "$@" > "$box/settings.conf"
}

# Runs the script under test. SHRINKIT_REPO is blank rather than unset: the script falls back to
# finding its data beside itself, and these tests want neither the checkout's presets nor its
# Quick Action template reachable.
optimize() {
  SHRINKIT_DIR="$1" SHRINKIT_REPO="" zsh "$OPTIMIZER"
}

# --------------------------------------------------------------------- sample videos

# A fixture that fails to build has to stop the run. Left missing, every test that uses it fails
# with a message about the feature under test, and the ffmpeg error that explains it went to
# /dev/null: four cut tests reported wrong lengths when ffmpeg dropped an option this file used.
fixture_built() {
  local name="$1" log="$2"
  [[ -f "$FIXTURES/$name" ]] && return 0
  print "  FAILED to build $name, ffmpeg said:"
  [[ -f "$log" ]] && tail -6 "$log"
  exit 1
}

# make_fixture <name> <ffmpeg args...>
make_fixture() {
  local name="$1" log
  shift
  [[ -f "$FIXTURES/$name" ]] && return
  print "  building $name ..."
  log="$(scratch)/ffmpeg.log"
  "$FFMPEG" -nostdin -y "$@" "$FIXTURES/$name" > "$log" 2>&1
  fixture_built "$name" "$log"
}

# A container that declares a much higher frame rate than the real one, the way ReplayKit does
# (r_frame_rate=120 there against an avg_frame_rate nearer 32-38): red, green, blue, blue, held for
# irregular durations on a 120Hz grid. Only exists to catch a regression back to
# setpts=N/FRAME_RATE/TB, which reads the declared rate rather than the real one and silently
# played this kind of file dozens of times too fast.
build_vfr_fixture() {
  [[ -f "$FIXTURES/vfr.mov" ]] && return
  print "  building vfr.mov ..."
  local work
  work="$(scratch)"
  "$FFMPEG" -nostdin -y -f lavfi -i color=c=red:s=160x90 -frames:v 1 "$work/f1.png" > /dev/null 2>&1
  "$FFMPEG" -nostdin -y -f lavfi -i color=c=green:s=160x90 -frames:v 1 "$work/f2.png" > /dev/null 2>&1
  "$FFMPEG" -nostdin -y -f lavfi -i color=c=blue:s=160x90 -frames:v 1 "$work/f3.png" > /dev/null 2>&1
  {
    print -r -- "file '$work/f1.png'"
    print -r -- "duration 2.5"
    print -r -- "file '$work/f2.png'"
    print -r -- "duration 1.833333"
    print -r -- "file '$work/f3.png'"
    print -r -- "duration 2.666667"
    print -r -- "file '$work/f3.png'"
  } > "$work/list.txt"
  # -fps_mode, not the -vsync this used to pass: ffmpeg removed that spelling, and with it the
  # fixture, silently. The two mean the same thing and -fps_mode has been accepted since 5.1.
  "$FFMPEG" -nostdin -y -f concat -safe 0 -i "$work/list.txt" -fps_mode vfr \
    -video_track_timescale 120 -c:v libx264 -pix_fmt yuv420p "$FIXTURES/vfr.mov" \
    > "$work/ffmpeg.log" 2>&1
  fixture_built vfr.mov "$work/ffmpeg.log"
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
  # blue/red/blue/green/blue, 3-1-4-1-3s. Red 3-4s and green 8-9s stand in for something that
  # must not survive a cut.
  make_fixture colored.mov -f lavfi -i "color=c=blue:s=640x360:r=30:d=3" \
    -f lavfi -i "color=c=red:s=640x360:r=30:d=1" \
    -f lavfi -i "color=c=blue:s=640x360:r=30:d=4" \
    -f lavfi -i "color=c=green:s=640x360:r=30:d=1" \
    -f lavfi -i "color=c=blue:s=640x360:r=30:d=3" \
    -f lavfi -i "testsrc2=s=160x90:r=30:d=12" \
    -f lavfi -i "sine=frequency=440:duration=12" \
    -filter_complex "[0][1][2][3][4]concat=n=5:v=1:a=0[bg];[bg][5]overlay=20:20[v]" \
    -map "[v]" -map 6:a -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
    -c:a aac -shortest
  # 4K, for the downscale test
  make_fixture tall.mov -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=5" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p
  # long 4K, so its encode lasts long enough to drop another file mid-run
  make_fixture big.mov -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=45" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p
  # Three interchangeable takes for the merge tests: same size, rate and codec, so they join
  # without re-encoding, and one flat colour each, so the result says which order actually ran.
  local colour
  for colour in red green blue; do
    make_fixture "take-${colour}.mov" -f lavfi -i "color=c=${colour}:s=320x180:r=30:d=2" \
      -c:v libx264 -preset ultrafast -pix_fmt yuv420p
  done
  # Two sound tracks, the way a screen recording of both the system and a microphone comes out
  make_fixture take-two-tracks.mov -f lavfi -i "color=c=red:s=320x180:r=30:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" -f lavfi -i "sine=frequency=880:duration=2" \
    -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac
  # A take that matches none of them: another size, and sound
  make_fixture take-loud.mov -f lavfi -i "color=c=white:s=640x360:r=30:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" -c:v libx264 -preset ultrafast \
    -pix_fmt yuv420p -c:a aac -shortest
  build_vfr_fixture
}

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

test_skips_work_already_done() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
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

test_cut_flag_cuts_without_any_sidecar() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"

  check "cuts the range it was given" duration_near "$out" 11
  check "with no sidecar written anywhere" missing "$work/clip.mov.cuts"
  check "and says a cut was applied" logged "$box" ', cut applied'
}

test_cut_flag_repeats_for_more_than_one_range() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut 3-4 --cut 8-9 "$work/clip.mov"

  check "cuts both ranges" duration_near "$out" 10
}

# The flag path has its own copy of the sort-and-merge pipeline, so it needs its own coverage of
# ranges arriving out of order and overlapping; the sidecar's copy being correct says nothing here.
test_cut_flag_sorts_and_merges_its_ranges() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  # out of order, and the last two overlap into one 3-5 stretch
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut 8-9 --cut 3-4.5 --cut 4-5 "$work/clip.mov"

  check "merges the overlap and keeps the separate range" duration_near "$out" 9
}

test_cut_flag_reaches_the_edges_the_same_way_the_sidecar_does() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 9-end "$work/clip.mov"

  check "'end' means the real length here too" duration_near "$out" 9
}

# Every other flag beats the file it has an equivalent in, so --cut beats the sidecar rather than
# adding to it. Silently applying both would be the surprise worth avoiding.
test_cut_flag_replaces_the_sidecar() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '0-6' > "$work/clip.mov.cuts" # would leave 6s; the flag below leaves 11s
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"

  check "applies the flag's range, not the sidecar's" duration_near "$out" 11
  check "and says the sidecar was ignored" logged "$box" 'using --cut, ignoring clip.mov.cuts'
}

test_cut_flag_rejects_a_bad_range_and_names_where_it_came_from() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 20-25 "$work/clip.mov"

  check "cuts nothing, the range is past the end" duration_near "$out" 12
  check "blames the flag, not a sidecar" logged "$box" "ignoring cut '20-25' from --cut"
  check "does not claim a cut happened" logged "$box" 'cut requested but none applied'
}

# --cut with the filename forgotten used to fall through to folder-watch mode, cutting the same
# seconds out of every queued recording, ignoring any sidecar they carried, and with
# keep_original = false deleting each source and sidecar it had just overridden.
test_cut_flag_with_no_file_is_refused() {
  local box code
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'keep_original = false'
  cp "$FIXTURES/colored.mov" "$box/input/queued.mov"
  print -r -- '0-6' > "$box/input/queued.mov.cuts"

  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 > /dev/null 2>&1 || code=$?

  check "stops with a usage error" test "$code" = 2
  check "leaves the queued recording alone" exists "$box/input/queued.mov"
  check "and its sidecar with it" exists "$box/input/queued.mov.cuts"
  check "writes nothing" empty_dir "$box/output"
}

test_cut_flag_with_no_range_is_refused() {
  local box work code
  box="$(sandbox)"
  settings "$box" 'speed = 1'

  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut > /dev/null 2>&1 || code=$?
  check "stops with a usage error" test "$code" = 2

  # An empty value is the same mistake one level up, a wrapper expanding a variable it never set.
  # Letting it through would count as "cuts were asked for" and suppress the recording's own
  # sidecar while adding no range to replace it.
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '3-4' > "$work/clip.mov.cuts"
  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut '' "$work/clip.mov" > /dev/null 2>&1 || code=$?

  check "an empty range is refused too" test "$code" = 2
  check "without touching the sidecar it would have suppressed" exists "$work/clip.mov.cuts"
  check "and without writing an output" missing "$work/clip.mp4"
}

# zsh expands a whole `local` line before any of its names becomes local, so a second assignment
# on that line that reads the first gets the CALLER's variable of that name, silently, or aborts
# the function under set -u when the caller has none. Proved, not reasoned:
#   zsh -c 'set -u; src=/OUTER; f() { local src="$1" cf="${src}.cuts"; print $cf }; f /ARG'
# prints /OUTER.cuts. The three places this file had all worked only because every caller happened
# to have the same variable set to the same value, which the next caller has no reason to.
test_no_local_line_reads_a_name_it_declares() {
  local -a lines names
  local line name bad=""
  lines=("${(@f)$(grep -n '^[[:space:]]*local .*=' "$OPTIMIZER")}")
  for line in "${lines[@]}"; do
    # Only assignments with a space in front of them: it keeps "concat=n=${n}" inside a filter
    # graph string from reading as a declaration of n.
    # sed, not tr: tr -d '[:space:]' eats the newlines between the matches too, and the names come
    # back as one run-together string that matches nothing.
    names=("${(@f)$(print -r -- "$line" | grep -o '[[:space:]][a-zA-Z_][a-zA-Z0-9_]*=' | sed 's/[^A-Za-z0-9_]//g')}")
    for name in "${names[@]}"; do
      [[ -n "$name" ]] || continue
      [[ "$line" == *"\${$name"* || "$line" == *"\$$name"* ]] && bad="${bad}${line}"$'\n'
    done
  done
  check "no local line reads a name it declares on the same line" test -z "$bad"
  [[ -n "$bad" ]] && print -r -- "$bad"
  return 0
}

# The keep segment after the last cut is written open, trim=start=4 with no end of its own, and
# nothing about the finished file can show that: closing it to the probed length encodes the same
# frames on a clip whose probed length is exact. Only the graph says which one was built, and the
# closed version drops whatever the probe read short.
test_cut_leaves_the_trailing_keep_segment_open() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"

  check "the trim after the cut carries no end of its own" logged "$box" 'trim=start=4,setpts'
  check "while the one before it is closed at the cut" logged "$box" 'trim=start=0:end=3,setpts'
}

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

  # out of order, and the last two overlap into one 3-5 stretch
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep 8-9 --keep 3-4.5 --keep 4-5 "$work/clip.mov"

  check "keeps the merged stretch and the separate one" duration_near "$out" 3
  check "with the green second joined on as the tail" color_at_is 2.5 "$out" 018001
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

test_keep_flag_replaces_the_sidecar() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '0-6' > "$work/clip.mov.cuts" # would leave 6s; the flag below leaves 2s
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 4-6 "$work/clip.mov"

  check "applies the flag's range, not the sidecar's" duration_near "$out" 2
  check "and says the sidecar was ignored" logged "$box" 'using --keep, ignoring clip.mov.cuts'
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
  print -r -- '0-6' > "$box/input/queued.mov.cuts"

  code=0
  msg="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --keep 3-4 2>&1 > /dev/null)" || code=$?

  check "stops with a usage error" test "$code" = 2
  # Same as above: 2 is also what an unknown flag exits with, so the message carries the claim.
  check "asking for the file it should keep from" \
    test "$msg" = "--keep needs the file to keep from, e.g. shrinkit --keep 1:00-2:00 recording.mov"
  check "leaves the queued recording alone" exists "$box/input/queued.mov"
  check "and its sidecar with it" exists "$box/input/queued.mov.cuts"
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
  # set. Letting it through would count as "ranges were asked for" and suppress the recording's own
  # sidecar while adding no range to replace it.
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  print -r -- '3-4' > "$work/clip.mov.cuts"
  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --keep '' "$work/clip.mov" > /dev/null 2>&1 || code=$?

  check "an empty range is refused too" test "$code" = 2
  check "without touching the sidecar it would have suppressed" exists "$work/clip.mov.cuts"
  check "and without writing an output" missing "$work/clip.mp4"
}

test_cuts_rich_text_sidecar_is_logged_and_skipped() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '{\rtf1\ansi 3-4}' > "$box/input/clip.mov.cuts"

  optimize "$box"
  # no dedicated check for this: the markup shows up verbatim in the ignoring-cut line, which says
  # plainly enough that the file was saved as Rich Text rather than plain text
  check "logs the markup it could not parse" logged "$box" 'ignoring cut .{.rtf1'
  check "keeps the full length" duration_near "$box/output/clip.mp4" 12
}

test_cuts_smart_dash_is_named_specifically() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- $'3–4' > "$box/input/clip.mov.cuts" # en dash, not a hyphen

  optimize "$box"
  check "names the smart dash rather than a generic parse error" logged "$box" 'looks like a smart dash'
}

test_cuts_trims_whitespace_around_the_dash() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3 - 4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "still cuts it, spaces and all" duration_near "$out" 11
}

test_cuts_do_not_distort_footage_with_a_misleading_frame_rate() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/vfr.mov" "$box/input/clip.mov"
  # well past the fixture's own ~6.9s, so nothing real is actually removed -- this is purely about
  # whether going through the cuts machinery at all distorts the timing of what survives
  print -r -- '900-901' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  # setpts=N/FRAME_RATE/TB read this fixture's declared 120fps instead of its real ~0.6fps and
  # compressed it to a fraction of a second; trim+concat rebases on the frames' own timestamps
  check "keeps the real length, not a frame-rate-based guess at it" duration_near "$out" 6.9
}

test_cuts_merge_overlapping_ranges() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '3-5' '4-6' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  # two overlapping lines merge into one 3-6 cut (3s), not two independently-trimmed stretches
  check "cuts the merged 3s span, not something narrower" duration_near "$out" 9
}

test_cuts_reaching_past_the_real_end_do_not_add_an_empty_trailing_stretch() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  # a CFR fixture does not reproduce this: the empty trailing branch only confuses fps= downstream
  # on footage like vfr.mov's, where FRAME_RATE and the real spacing between frames disagree
  cp "$FIXTURES/vfr.mov" "$box/input/clip.mov"
  print -r -- '5-999' > "$box/input/clip.mov.cuts" # vfr.mov is ~6.9s; nothing survives past 5s

  optimize "$box"
  out="$box/output/clip.mp4"
  check "keeps the first 5s and nothing more" duration_near "$out" 5
}

test_cuts_in_the_middle_keep_both_sides_on_misleading_frame_rate_footage() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  # a single ordinary cut with footage before AND after it, on the fixture that mimics a real
  # ReplayKit recording -- every existing vfr.mov test collapses to one kept stretch and missed a
  # bug that reused one filter label ([vnorm]) for every stretch, silently feeding every stretch
  # after the first the raw un-normalized frames: on this fixture that dropped ~89% of the video
  cp "$FIXTURES/vfr.mov" "$box/input/clip.mov"
  print -r -- '1-2' > "$box/input/clip.mov.cuts" # vfr.mov is ~6.9s; keeps [0,1) and [2,end)

  optimize "$box"
  out="$box/output/clip.mp4"
  check "keeps roughly all of both sides of the cut" duration_near "$out" 5.9
}

test_cuts_still_respect_the_fps_cap_once_speed_changes_the_frame_rate() {
  local box out frames rate
  box="$(sandbox)"
  settings "$box" 'speed = 3' 'fps = 20'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  # cutting keeps a fixed frame rate before speeding up, so speed x3 on that is real content moving
  # 3x faster -- nothing re-applied the fps cap afterward, so this used to land near 60fps (native,
  # doubled by an ffmpeg default) rather than the configured 20
  rate="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$out")"
  frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$out")"
  check "declares the configured 20fps, not something speed-inflated" test "$rate" = "20/1"
  check "and the frame count matches it" roughly_equal "$frames" 73 5
}

test_cuts_accept_a_range_that_is_exactly_the_minimum_length() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/vfr.mov" "$box/input/clip.mov"
  # 6.1 - 6.0 lands a hair under 0.1 in IEEE-754 double subtraction; a plain, deliberately-typed
  # 0.1s cut should not be silently discarded over that
  print -r -- '6.0-6.1' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip.mp4"
  check "accepts the exact-0.1s range" logged "$box" ', cut applied'
  check "does not treat it as too short" not_logged "$box" 'too short'
}

test_mark_cuts_with_no_files_is_refused() {
  local code=0
  zsh "$OPTIMIZER" mark-cuts > /dev/null 2>&1 || code=$?
  check "stops with a usage error" test "$code" = 2
}

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

test_one_shot_optimizes_a_file_in_place() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  # a file living outside the input folder, like something you right-click in Finder
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov"

  check "writes the result next to the source" exists "$work/recording.mp4"
  check "leaves the original in place" exists "$work/recording.mov"
  check "halves the duration" duration_near "$work/recording.mp4" 6
  check "does not use the watch folder" empty_dir "$box/output"
}

test_one_shot_handles_several_files() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/a.mov"
  cp "$FIXTURES/withaudio.mov" "$work/b.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/a.mov" "$work/b.mov"
  check "optimizes the first" exists "$work/a.mp4"
  check "optimizes the second" exists "$work/b.mp4"
}

test_a_failed_move_into_place_is_reported_not_silent() {
  local box work fakebin tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  # Stands in for mv refusing to put the result in place, for whatever reason the folder has.
  fakebin="$(scratch)"
  print -rl -- '#!/bin/zsh' 'print -u2 "mv: refused by the fake"' 'exit 1' > "$fakebin/mv"
  chmod +x "$fakebin/mv"

  TMPDIR="$tmp" PATH="$fakebin:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov"

  check "does not silently succeed" missing "$work/clip.mp4"
  check "leaves no orphaned temp file behind" test -z "$(ls -A "$tmp")"
  check "names the actual problem" logged "$box" 'could not move clip.mp4'
  check "with mv's own reason beside it" logged "$box" 'mv: refused by the fake'
  check "leaves the source in place" exists "$work/clip.mov"
}

test_one_shot_skips_a_cuts_sidecar_selected_alongside_the_video() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"
  print -r -- '1-2' > "$work/recording.mov.cuts"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov" "$work/recording.mov.cuts"

  check "shrinks the video" exists "$work/recording.mp4"
  check "does not try to encode the sidecar" logged "$box" "skip   recording.mov.cuts (not a video)"
  check "so it is never reported as a failed shrink" not_logged "$box" 'FAILED'
}

test_flags_are_answered_not_swallowed() {
  local box out code=0
  box="$(scratch)"
  rmdir "$box" # so we can tell whether --help went on to build the working folders

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --help)"
  check "prints usage" test -n "$out"
  check "and does nothing else" missing "$box"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --nope > /dev/null 2>&1 || code=$?
  check "rejects an unknown flag" test "$code" = 2
}

test_flags_beat_the_config_file() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 28'
  work="$(scratch)"
  cp "$FIXTURES/withaudio.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --speed 4 --no-remove-audio "$work/clip.mov"

  check "takes the speed from the flag" duration_near "$out" 3
  check "names the file after it" exists "$out"
  check "takes the boolean from the flag too" has_audio "$out"
}

test_flags_that_make_no_sense_are_refused() {
  local box code
  box="$(sandbox)"
  settings "$box" 'speed = 2'

  for flag in --crf --nope --no-speed; do
    code=0
    SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
      zsh "$OPTIMIZER" "$flag" > /dev/null 2>&1 || code=$?
    check "refuses $flag" test "$code" = 2
  done
}

test_a_result_is_made_outside_the_folder_it_lands_in() {
  local box work tmp
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  tmp="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  TMPDIR="$tmp" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1

  # A right-click entry cannot rename or delete a file that ffmpeg made on the Desktop, so a half
  # made file beside the recording is one it can neither finish nor clean up. Measured with a probe
  # entry on a real Desktop file; the move in from elsewhere is allowed.
  check "the result lands beside the recording" exists "$work/clip.mp4"
  check "with ffmpeg writing into the temporary folder" logged "$box" "to '$tmp/shrinkit."
  check "and nothing half-made left beside it" test -z "$(ls -A "$work" | grep part)"
  check "nor in the temporary folder" test -z "$(ls -A "$tmp")"
}

test_config_show_lists_what_is_in_effect() {
  local box out
  box="$(sandbox)"
  settings "$box" 'crf = 31'

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config)"
  check "reports the value from the file" grep -q '^crf = 31$' <<< "$out"
  check "and a setting the file never named" grep -q '^codec = h264$' <<< "$out"
}

test_config_show_reports_the_default_when_the_file_is_wrong() {
  local box out
  box="$(sandbox)"
  settings "$box" 'crf = banana'

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config)"

  # A run encodes this at 28 and logs why. Printing the file's own text here let the typo look
  # live, which is the one thing this command exists to answer.
  check "shows the value a run would use" grep -q '^crf = 28' <<< "$out"
  check "and never the one that was refused" lacks "$out" "crf = banana"
  check "and says what it is ignoring" contains "$out" "ignoring 'banana'"
}

test_config_set_refuses_a_value_outside_the_range() {
  local box code=0 out
  box="$(sandbox)"
  settings "$box" 'crf = 31'

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config crf 99 2>&1)" || code=$?

  # crf stops at 51. Writing 99 and rejecting it on the next run left the file holding a number no
  # recording would ever be encoded at.
  check "stops rather than writing it" test "$code" = 2
  check "and names the range" contains "$out" "want 0-51"
  check "and leaves the file as it was" grep -q '^crf = 31$' "$box/settings.conf"
}

test_config_set_refuses_a_number_too_long_for_arithmetic() {
  local box code out key
  box="$(sandbox)"
  settings "$box" 'crf = 31' 'fps = 30'

  # zsh truncates a digit string past 19 places to something negative, so a bare <= comparison
  # passes it and prints its own diagnostic doing so. Both reached the user: the command reported
  # success on a value no run can use, with "number truncated after 19 digits" above it.
  for key in crf fps; do
    code=0
    out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
      zsh "$OPTIMIZER" config "$key" 99999999999999999999 2>&1)" || code=$?
    check "$key stops rather than writing it" test "$code" = 2
    check "and leaks no zsh diagnostic" lacks "$out" "truncated"
  done
  check "the file keeps the value it had" grep -q '^crf = 31$' "$box/settings.conf"
  check "and the other one too" grep -q '^fps = 30$' "$box/settings.conf"
}

test_a_setting_that_is_not_one_leaves_a_line_in_the_log() {
  local box
  box="$(sandbox)"
  settings "$box" 'crf = 31' 'output_suffix = -2x'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" > /dev/null 2>&1

  # output_suffix was a setting once. Dropping it silently left a config file that looked as if it
  # still did something, and an output named by rules nobody could find.
  check "names the key it dropped" logged "$box" "ignoring 'output_suffix'"
  check "and the file it came from" logged "$box" "settings.conf"
  check "while the run itself goes through" exists "$box/output/clip.mp4"
}

test_a_preset_key_that_is_not_a_setting_is_logged_too() {
  local box
  box="$(sandbox)"
  settings "$box" 'crf = 31'
  mkdir -p "$box/presets"
  print -rl -- 'crf = 20' 'output_suffix = -hq' > "$box/presets/sharp.conf"
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --preset sharp > /dev/null 2>&1

  check "a preset goes through the same reader" logged "$box" "ignoring 'output_suffix' in sharp.conf"
}

test_config_set_edits_the_line_in_place() {
  local box
  box="$(sandbox)"
  print -rl -- '# how sharp' 'crf = 28' '' 'speed = 2' > "$box/settings.conf"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config crf 33 > /dev/null

  check "writes the new value" grep -q '^crf = 33$' "$box/settings.conf"
  check "keeps the comment above it" grep -q '^# how sharp$' "$box/settings.conf"
  check "leaves the other settings" grep -q '^speed = 2$' "$box/settings.conf"
  check "writes it only once" test "$(grep -c '^crf' "$box/settings.conf")" = 1
}

test_config_set_appends_a_setting_that_was_missing() {
  local box
  box="$(sandbox)"
  print -r -- 'speed = 2' > "$box/settings.conf"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config remove-audio false > /dev/null
  check "adds it under its real name" grep -q '^remove_audio = false$' "$box/settings.conf"
}

test_config_set_refuses_a_setting_that_does_not_exist() {
  local box code=0
  box="$(sandbox)"
  settings "$box" 'speed = 2'

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" config nope 1 > /dev/null 2>&1 || code=$?
  check "stops with a usage error" test "$code" = 2
  check "and writes nothing" test "$(grep -c nope "$box/settings.conf")" = 0
}

# preset <sandbox> <name> <line...>
preset() {
  local box="$1" name="$2"
  shift 2
  mkdir -p "$box/presets"
  print -rl -- "$@" > "$box/presets/$name.conf"
}

test_preset_is_read_on_top_of_the_config() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'crf = 28'
  preset "$box" chat 'speed = 3' 'crf = 32'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --preset chat "$work/clip.mov"

  check "names the result after the preset" exists "$work/clip-chat.mp4"
  check "and the length its settings ask for" duration_near "$work/clip-chat.mp4" 4
}

test_preset_loses_to_a_flag() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  preset "$box" chat 'speed = 3'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --preset chat --speed 4 "$work/clip.mov"

  # 12s at the flag's 4x is 3s; the preset's 3x would have left 4s
  check "the flag wins" duration_near "$work/clip-chat.mp4" 3
}

test_preset_that_does_not_exist_is_refused() {
  local box code
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --preset nope > /dev/null 2>&1 || code=$?
  check "stops rather than guessing" test "$code" = 2
  check "leaves the file alone" exists "$box/input/clip.mov"

  # The same for the Quick Action side. HOME is the sandbox here: the assertion is about a folder
  # the script must not write into, and pointing it at the real one makes a passing test depend on
  # the developer's own machine and a failing one damage it.
  code=0
  HOME="$box/home" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" preset install nope > /dev/null 2>&1 || code=$?
  check "refuses to build an action for it" test "$code" = 2
  check "and builds nothing" missing "$box/home/Library/Services/shrinkit: nope.workflow"
}

# A Homebrew-shaped install: the script in a versioned Cellar directory, its data where a keg puts
# it, and the per-formula opt symlink brew keeps pointing at the current version.
brew_keg() {
  local box="$1" keg="$1/brew/Cellar/shrinkit/9.9"
  mkdir -p "$keg/bin" "$keg/share/shrinkit" "$box/brew/opt" "$box/home"
  cp "$OPTIMIZER" "$keg/bin/shrinkit"
  chmod +x "$keg/bin/shrinkit"
  # lib/ goes in beside the data: the script reads it back as <keg>/share/shrinkit/lib, and the
  # formula has to install it or nothing runs at all.
  cp -R "$REPO_DIR/quick-action" "$REPO_DIR/presets" "$REPO_DIR/lib" "$keg/share/shrinkit/"
  ln -sfn "$keg" "$box/brew/opt/shrinkit"
  # The keg's presets are the stock copies setup seeds on a first install; an entry is built from
  # the one in the working folder, so that is where this has to be.
  mkdir -p "$box/presets"
  cp "$REPO_DIR/presets/2x.conf" "$box/presets/"
}

# A cask-shaped install: the release staged whole under Caskroom/<token>/<version>/shrinkit-<version>,
# the way a GitHub tag tarball unpacks, and the binary stanza's link in the prefix's own bin.
brew_cask() {
  local box="$1" staged="$1/brew/Caskroom/shrinkit/9.9/shrinkit-9.9"
  mkdir -p "$staged" "$box/brew/bin" "$box/home"
  cp "$OPTIMIZER" "$staged/shrinkit.sh"
  chmod +x "$staged/shrinkit.sh"
  cp -R "$REPO_DIR/quick-action" "$REPO_DIR/presets" "$REPO_DIR/lib" "$REPO_DIR/settings.conf" "$staged/"
  ln -sfn "$staged/shrinkit.sh" "$box/brew/bin/shrinkit"
}

# The command a Quick Action runs: where the script has to write its own path down.
action_command() {
  plutil -extract actions.0.action.ActionParameters.COMMAND_STRING raw -o - \
    "$1/Contents/document.wflow" 2> /dev/null
}

test_a_part_that_cannot_be_read_stops_the_run_and_says_so() {
  local box out code
  box="$(scratch)"
  brew_keg "$box"
  rm -f "$box/brew/Cellar/shrinkit/9.9/share/shrinkit/lib/merge.zsh"

  code=0
  out="$(HOME="$box/home" SHRINKIT_DIR="$box" \
    "$box/brew/opt/shrinkit/bin/shrinkit" --help 2>&1)" || code=$?

  # A packaging mistake, not a missing feature: carrying on would fail later somewhere that reads
  # as a bug in whatever the user was actually doing.
  check "stops rather than running without it" test "$code" = 1
  check "and names the file it could not read" contains "$out" "merge.zsh"
}

test_a_keg_install_finds_its_template_without_a_checkout() {
  local box cmd
  box="$(scratch)"
  brew_keg "$box"
  settings "$box" 'speed = 2'

  HOME="$box/home" SHRINKIT_DIR="$box" \
    "$box/brew/opt/shrinkit/bin/shrinkit" preset install 2x > /dev/null 2>&1

  cmd="$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")"
  check "builds the entry with nothing handed in from outside" test -n "$cmd"
}

test_a_keg_install_writes_a_path_that_survives_an_upgrade() {
  local box cmd
  box="$(scratch)"
  brew_keg "$box"
  settings "$box" 'speed = 2'

  HOME="$box/home" SHRINKIT_DIR="$box" \
    "$box/brew/opt/shrinkit/bin/shrinkit" preset install 2x > /dev/null 2>&1
  cmd="$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")"

  # The Cellar path is what ZSH_ARGZERO:A answers however the script was reached, and it is gone
  # after the next brew upgrade, taking every Finder entry with it and saying nothing.
  check "names the per-formula path" contains "$cmd" "/opt/shrinkit/bin/shrinkit"
  check "not the versioned one" lacks "$cmd" "/Cellar/"
}

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
  settings "$box"
  work="$(scratch)"
  recorded_copy "$FIXTURES/take-red.mov" "$work/one.mov" 2026-01-01T10:00:00
  recorded_copy "$FIXTURES/take-loud.mov" "$work/two.mov" 2026-01-01T10:05:00
  out="$work/one-merged.mp4"

  run_merge "$box" "$work/one.mov" "$work/two.mov"

  check "says why it had to re-encode" logged "$box" 'differ in size, codec or sound'
  check "still produces one file" exists "$out"
  check "that plays" playable "$out"
  check "as long as the takes together" duration_near "$out" 4
  check "at the larger of the two sizes" test "$(height_of "$out")" = 360
  check "with the sound the other take had" has_audio "$out"
  check "and keeps the order" takes_are "$out" red grey
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

# --------------------------------------------------------------------- the numeric locale

# A locale the machine does not actually have falls back to C, where neither bug below can appear:
# without this, both tests would come back green over nothing at all.
comma_locale_is_real() {
  [[ "$(LC_ALL=uk_UA.UTF-8 awk 'BEGIN { printf "%.1f", 1.5 }')" == "1,5" ]]
}

# awk prints a float through the locale, so atempo_chain built "atempo=1,5000" and ffmpeg read the
# comma as the separator before a filter named 5000. Every run that kept its audio at a speed other
# than 1 died outright.
test_a_comma_decimal_locale_leaves_the_audio_path_working() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 3' 'remove_audio = false' 'fps = 0'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  check "the locale this test needs is really a comma one" comma_locale_is_real
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" LC_NUMERIC=uk_UA.UTF-8 zsh "$OPTIMIZER"

  out="$box/output/clip.mp4"
  check "writes the output" exists "$out"
  check "keeps the audio" has_audio "$out"
  check "at the speed that was asked for" duration_near "$out" 4
  check "and loses no filter to a comma" not_logged "$box" 'No such filter'
}

# awk reads a float through the locale as well, so "0:02.9" came back as a plain 2 and the cut
# landed most of a second early, with nothing in the log to say so. LC_ALL here rather than
# LC_NUMERIC: it outranks the pin, so the script has to move it aside for the pin to hold.
test_a_comma_decimal_locale_does_not_move_a_fractional_cut() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'fps = 0'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  # colored.mov is 12s. Truncating both ends of this range to whole seconds removes 7s and leaves
  # 5, where the range as typed removes 6.2s and leaves 5.8.
  print -r -- '0:02.9-0:09.1' > "$box/input/clip.mov.cuts"

  check "the locale this test needs is really a comma one" comma_locale_is_real
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" LC_ALL=uk_UA.UTF-8 zsh "$OPTIMIZER"

  out="$box/output/clip.mp4"
  check "cuts the fraction it was given, not the whole second" duration_near "$out" 5.8
  check "and reports the cut as applied" logged "$box" ', cut applied'
}

# --------------------------------------------------------------------- setup and teardown

# A sandboxed HOME, a Desktop to put the shortcut on, and a launchctl that records what it was
# asked for instead of doing it. The real one needs an Aqua session CI does not have, and on a
# developer's machine a test would boot out the agent they are actually using.
setup_box() {
  local box="$1"
  mkdir -p "$box/home/Desktop" "$box/bin"
  # Records what it was asked for, and answers bootout the way launchd does: non-zero when the
  # service was never loaded. teardown reads that status to tell "there was no agent" from "there
  # was one and it is gone", so a stub that always succeeded would hide the difference.
  cat > "$box/bin/launchctl" << STUB
#!/bin/zsh
print -r -- "\$@" >> "$box/launchctl.log"
case "\$1" in
  bootstrap) : > "$box/loaded" ;;
  bootout)
    [[ -f "$box/loaded" ]] || exit 3
    rm -f "$box/loaded"
    ;;
esac
STUB
  chmod +x "$box/bin/launchctl"
}

# run_setup <box> [base folder]. SHRINKIT_REPO is deliberately left unset: finding presets/ and
# quick-action/ beside the script is the thing a Homebrew install depends on.
run_setup() {
  local box="$1" base="${2:-$1/work}"
  HOME="$box/home" SHRINKIT_DIR="$base" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    zsh "$OPTIMIZER" setup
}

# run_teardown <box> [base folder]. With no base folder the variable is unset, which is how a
# custom install is usually torn down: from a new shell that never exported it.
run_teardown() {
  local box="$1" base="${2:-}"
  if [[ -n "$base" ]]; then
    HOME="$box/home" SHRINKIT_DIR="$base" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
      zsh "$OPTIMIZER" teardown
  else
    HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" zsh "$OPTIMIZER" teardown
  fi
}

plist_value() {
  plutil -extract "$2" raw -o - "$1" 2> /dev/null
}
links_to() {
  [[ -L "$1" && "${1:A}" == "${2:A}" ]]
}
is_dir() {
  [[ -d "$1" && ! -L "$1" ]]
}
action_count() {
  print -r -- "${#${(@f)$(print -rl -- "$1"/shrinkit:*.workflow(N))}}"
}

test_setup_registers_the_script_that_is_running() {
  local box plist
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "writes the agent" exists "$plist"
  check "watching the input folder" \
    test "$(plist_value "$plist" WatchPaths.0)" = "$box/work/input"
  check "carrying the working folder" \
    test "$(plist_value "$plist" EnvironmentVariables.SHRINKIT_DIR)" = "$box/work"
  # The installer used to copy the script and point the agent at the copy, so a git pull left the
  # agent running yesterday's version with nothing anywhere to say so.
  check "runs the link on the PATH" \
    test "$(plist_value "$plist" ProgramArguments.0)" = "$box/home/.local/bin/shrinkit"
  check "which is this very script" links_to "$box/home/.local/bin/shrinkit" "$OPTIMIZER"
  # The agent and the menu entries have to name the same program, or an upgrade or a move fixes
  # one and leaves the other pointing at nothing.
  check "and the menu entries name it too" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" \
    "$box/home/.local/bin/shrinkit"
  check "and hands the agent no data directory to go stale" \
    test -z "$(plist_value "$plist" EnvironmentVariables.SHRINKIT_REPO)"
}

test_setup_makes_the_folders_and_loads_the_agent() {
  local box dir
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  for dir in input output .processed .logs presets; do
    check "creates $dir/" test -d "$box/work/$dir"
  done
  check "installs the settings" exists "$box/work/settings.conf"
  check "links the Desktop shortcut" links_to "$box/home/Desktop/work" "$box/work"
  # Reloading rather than loading: bootstrap over an already-loaded label is an error, so a second
  # setup would fail without the bootout in front of it.
  check "boots the old agent out" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "then bootstraps the new one" \
    grep -q "^bootstrap gui/$(id -u) $box/home/Library/LaunchAgents/com.shrinkit.plist$" "$box/launchctl.log"
}

test_setup_builds_one_entry_per_preset_and_sweeps_the_rest() {
  local box services
  box="$(scratch)"
  setup_box "$box"
  services="$box/home/Library/Services"
  mkdir -p "$services"
  cp -R "$REPO_DIR/quick-action/shrinkit.workflow" "$services/shrinkit: gone.workflow"

  run_setup "$box" > /dev/null 2>&1

  # three stock presets, plus mark cuts and merge
  check "one entry per preset plus the two that are not presets" \
    test "$(action_count "$services")" = 5
  check "a preset that no longer exists leaves no entry" missing "$services/shrinkit: gone.workflow"
  check "and the preset entries are there" exists "$services/shrinkit: 2x.workflow/Contents/Info.plist"
}

test_setup_run_again_keeps_the_settings_and_the_presets() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1

  print -r -- "crf = 19" >> "$box/work/settings.conf"
  rm -f "$box/work/presets/tiny.conf"
  run_setup "$box" > /dev/null 2>&1

  check "never overwrites the settings" grep -q "crf = 19" "$box/work/settings.conf"
  check "and does not repopulate a preset you deleted" missing "$box/work/presets/tiny.conf"
  check "so its entry is gone too" missing "$box/home/Library/Services/shrinkit: tiny.workflow"
}

test_setup_renames_the_presets_that_were_renamed() {
  local box
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/work/presets"
  print -r -- "crf = 32" > "$box/work/presets/chat.conf"
  print -r -- "crf = 18" > "$box/work/presets/hq.conf"

  run_setup "$box" > /dev/null 2>&1

  check "chat becomes tiny" exists "$box/work/presets/tiny.conf"
  check "and is gone under the old name" missing "$box/work/presets/chat.conf"
  check "hq becomes sharp" exists "$box/work/presets/sharp.conf"
  check "keeping what was in it" grep -q "crf = 18" "$box/work/presets/sharp.conf"
}

test_setup_never_replaces_a_real_folder_on_the_desktop() {
  local box
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/home/Desktop/work"
  print -r -- "mine" > "$box/home/Desktop/work/notes.txt"

  run_setup "$box" > /dev/null 2>&1

  check "leaves the folder as it found it" is_dir "$box/home/Desktop/work"
  check "with what was inside it" exists "$box/home/Desktop/work/notes.txt"
}

test_setup_replaces_an_older_installs_copy_with_a_link() {
  local box link
  box="$(scratch)"
  setup_box "$box"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "$link:h"
  print -r -- "#!/bin/zsh" > "$link"
  chmod +x "$link"

  run_setup "$box" > /dev/null 2>&1

  check "the stale copy becomes a link to the real script" links_to "$link" "$OPTIMIZER"
}

test_setup_run_from_the_path_link_leaves_itself_runnable() {
  local box link
  box="$(scratch)"
  setup_box "$box"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "${link:h}"
  cp "$OPTIMIZER" "$link"
  chmod +x "$link"
  cp -R "$REPO_DIR/quick-action" "$REPO_DIR/presets" "$REPO_DIR/settings.conf" "${link:h}/"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$link" setup > /dev/null 2>&1

  # The shape an install takes once its checkout is gone: this file is the only shrinkit left, and
  # it is the one running. Relinking it over itself leaves a link pointing at its own name, and
  # there is then no shrinkit at all.
  check "the script it was run from survives" test -f "$link"
  check "and is still a script" zsh -n "$link"
}

test_setup_points_the_privacy_grant_at_the_registered_binary() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  # Desktop, Documents and Downloads are the three macOS refuses a background job in until the
  # binary is granted Full Disk Access by hand.
  out="$(run_setup "$box" "$box/home/Desktop/clips" 2>&1)"

  check "says the one-time step is needed" contains "$out" "Full Disk Access"
  # Scoped to the line that carries the path to paste. Asserting against the whole output passes on
  # the "On your PATH" line setup prints earlier, whatever the note itself says.
  # The grant is per binary path. A note naming anything but the path the agent actually runs sends
  # the user to grant access to a file that is never the one refused.
  check "and names the path the agent runs" \
    contains "$(print -r -- "$out" | grep 'paste:')" "$box/home/.local/bin/shrinkit"
  check "no shortcut to a folder already on the Desktop" \
    missing "$box/home/Desktop/clips/clips"
}

# A checkout inside Desktop, Documents or Downloads, which is where people put a clone often
# enough that this is the common case rather than an edge one.
guarded_checkout() {
  local box="$1" where="$1/home/Desktop/repos/shrinkit"
  mkdir -p "${where:h}"
  cp "$OPTIMIZER" "$where/../shrinkit.sh" 2> /dev/null
  mkdir -p "$where"
  cp "$OPTIMIZER" "$where/shrinkit.sh"
  chmod +x "$where/shrinkit.sh"
  cp -R "$REPO_DIR/lib" "$REPO_DIR/presets" "$REPO_DIR/quick-action" "$REPO_DIR/settings.conf" "$where/"
  print -r -- "$where/shrinkit.sh"
}

test_setup_copies_a_checkout_out_of_a_privacy_protected_folder() {
  local box script
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$script" setup > /dev/null 2>&1

  # Neither the agent nor a Finder entry can read a file in there, link or no link: zsh answers
  # "can't open input file" and nothing says why. Measured on a real checkout in ~/Desktop, where a
  # dropped recording sat unprocessed until the same install ran from outside.
  check "leaves a real file on the PATH, not a link into the folder" \
    test -f "$box/home/.local/bin/shrinkit" -a ! -L "$box/home/.local/bin/shrinkit"
  check "with the parts beside it, laid out like a prefix" \
    test -f "$box/home/.local/share/shrinkit/lib/merge.zsh"
  check "and the data too" test -f "$box/home/.local/share/shrinkit/quick-action/shrinkit.workflow/Contents/Info.plist"
}

test_setup_points_the_agent_and_the_entries_at_the_copy() {
  local box script plist
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$script" setup > /dev/null 2>&1

  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "the agent runs the copy" \
    test "$(plist_value "$plist" ProgramArguments.0)" = "$box/home/.local/bin/shrinkit"
  check "and never the guarded checkout" \
    lacks "$(plist_value "$plist" ProgramArguments.0)" "/Desktop/"
  check "the menu entries run the copy too" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" \
    "$box/home/.local/bin/shrinkit"
  check "and never the guarded checkout either" \
    lacks "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "/Desktop/repos"
}

test_setup_replaces_a_link_left_by_an_older_install_with_the_copy() {
  local box script link
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"
  link="$box/home/.local/bin/shrinkit"
  mkdir -p "${link:h}"
  ln -sfn "$script" "$link"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$script" setup > /dev/null 2>&1

  # cp onto a symlink writes through it and leaves the link alone, which is exactly the shape an
  # upgrade from the version that always linked arrives in.
  check "the link becomes a real file" test ! -L "$link"
  check "and the copy runs" test -x "$link"
}

test_setup_says_when_another_shrinkit_answers_on_the_path() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  mkdir -p "$box/otherbin"
  print -r -- '#!/bin/zsh' > "$box/otherbin/shrinkit"
  chmod +x "$box/otherbin/shrinkit"

  # What a keg does on a default macOS PATH, where /opt/homebrew/bin comes before ~/.local/bin.
  out="$(PATH="$box/otherbin:$PATH" HOME="$box/home" SHRINKIT_DIR="$box/work" \
    SHRINKIT_LAUNCHCTL="$box/bin/launchctl" zsh "$OPTIMIZER" setup 2>&1)"

  check "names the one the terminal would run" contains "$out" "$box/otherbin/shrinkit"
  check "and the one the agent will run" \
    contains "$out" "now run $box/home/.local/bin/shrinkit"
  check "and says both are in play" contains "$out" "Two installs are in play"
  # teardown clears ~/.local whichever binary runs it, so telling anyone to tear down "the one you
  # do not want" sends them to delete the install they meant to keep.
  check "and never offers to tear down one of them" lacks "$out" "do not want"
  check "but says to set up the one to keep" contains "$out" "run 'setup'"
}

test_setup_stays_quiet_when_the_path_agrees_with_what_it_registered() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  out="$(PATH="$box/home/.local/bin:$PATH" HOME="$box/home" SHRINKIT_DIR="$box/work" \
    SHRINKIT_LAUNCHCTL="$box/bin/launchctl" zsh "$OPTIMIZER" setup 2>&1)"

  check "says nothing about a second install" lacks "$out" "Two installs"
  # Pins the quiet branch rather than just the absence of a word: a warning that crashed, or a
  # setup that stopped before reaching it, would read as silence too.
  check "and got to the end of setup" contains "$out" "Done."
}

test_teardown_reports_an_agent_it_unloaded_without_a_plist() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  # The plist deleted by hand, the agent left bootstrapped. Reporting off the file alone said
  # there was no agent in the same breath as unloading one.
  rm -f "$box/home/Library/LaunchAgents/com.shrinkit.plist"

  out="$(run_teardown "$box" 2>&1)"

  check "boots it out" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "and says the agent went" contains "$out" "the agent"
  check "rather than claiming there was none" lacks "$out" "Nothing to remove"
}

test_a_cask_install_registers_the_link_that_survives_an_upgrade() {
  local box plist
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # The staged folder is named for the version and goes on the next upgrade, taking every entry
  # that names it along; brew repoints the bin link at the new one instead.
  plist="$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "the agent runs brew's link" test "$(plist_value "$plist" ProgramArguments.0)" = "${box:A}/brew/bin/shrinkit"
  check "and never the versioned folder" lacks "$(plist_value "$plist" ProgramArguments.0)" "Caskroom"
  check "nor does a menu entry" \
    lacks "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "Caskroom"
  check "and it makes no PATH link of its own" missing "$box/home/.local/bin/shrinkit"
}

test_a_cask_install_retires_an_earlier_checkout_copy() {
  local box
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/.local/bin" "$box/home/.local/share/shrinkit"
  cp "$OPTIMIZER" "$box/home/.local/bin/shrinkit"
  cp -R "$REPO_DIR/lib" "$box/home/.local/share/shrinkit/"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # Left in place, the old copy answers to "shrinkit" wherever ~/.local/bin comes first on the PATH
  # while the agent and the menu run brew's.
  check "removes the old copy on the PATH" missing "$box/home/.local/bin/shrinkit"
  check "and the parts that came with it" missing "$box/home/.local/share/shrinkit"
}

test_a_cask_install_leaves_a_different_shrinkit_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  brew_cask "$box"
  mkdir -p "$box/home/.local/bin"
  print -rl -- '#!/bin/sh' 'echo somebody else' > "$box/home/.local/bin/shrinkit"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$box/brew/bin/shrinkit" setup > /dev/null 2>&1

  # This runs on every brew install and upgrade, so a file that only shares the name survives it.
  check "keeps a file that is not this script" grep -q "somebody else" "$box/home/.local/bin/shrinkit"
}

# setup the way Homebrew runs it: `env -i` with a short whitelist, so SHRINKIT_DIR never arrives.
setup_as_brew_does() {
  local box="$1"
  env -i HOME="$box/home" PATH="$PATH" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    zsh "$OPTIMIZER" setup
}

test_a_folder_named_once_survives_a_setup_without_it() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/clips" > /dev/null 2>&1
  run_teardown "$box" > /dev/null 2>&1

  # What brew upgrade does: teardown from the old version, then setup with SHRINKIT_DIR cleared.
  setup_as_brew_does "$box" > /dev/null 2>&1

  check "the agent still watches the folder that was chosen" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/clips/input"
  check "and no default folder was made instead" missing "$box/home/Movies/shrinkit"
}

test_config_folder_moves_the_install_to_the_new_folder() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  print -r -- "crf = 19" >> "$box/work/settings.conf"

  out="$(HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" zsh "$OPTIMIZER" config folder "$box/elsewhere" 2>&1)"

  check "the agent watches the new folder" \
    test "$(plist_value "$box/home/Library/LaunchAgents/com.shrinkit.plist" WatchPaths.0)" = "$box/elsewhere/input"
  check "the menu entries work in it" \
    contains "$(action_command "$box/home/Library/Services/shrinkit: 2x.workflow")" "SHRINKIT_DIR=\"$box/elsewhere\""
  check "the Desktop shortcut follows" links_to "$box/home/Desktop/elsewhere" "$box/elsewhere"
  check "and the old one is gone" missing "$box/home/Desktop/work"
  check "the old folder and what is in it stay" grep -q "crf = 19" "$box/work/settings.conf"
  check "and it says so" contains "$out" "stays there"
  check "an upgrade keeps it" test "$(setup_as_brew_does "$box" 2>&1 | grep -c "Base folder: $box/elsewhere")" = 1
  check "and config folder names it" \
    test "$(HOME="$box/home" zsh "$OPTIMIZER" config folder)" = "$box/elsewhere"
}

test_teardown_removes_the_copy_setup_made_out_of_a_guarded_checkout() {
  local box script out
  box="$(scratch)"
  setup_box "$box"
  script="$(guarded_checkout "$box")"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$script" setup > /dev/null 2>&1
  check "the copy is there to begin with" exists "$box/home/.local/share/shrinkit/lib/merge.zsh"

  out="$(run_teardown "$box" "$box/work" 2>&1)"

  # An uninstall that says it is finished while 48K of the tool sits under ~/.local is not one.
  check "takes the parts with it" missing "$box/home/.local/share/shrinkit"
  check "and the copy on the PATH" missing "$box/home/.local/bin/shrinkit"
  check "and says where they went" contains "$out" "$box/home/.local/share/shrinkit"
}

test_teardown_under_a_keg_claims_no_path_entry_of_its_own() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  brew_keg "$box"

  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$box/brew/opt/shrinkit/bin/shrinkit" setup > /dev/null 2>&1
  out="$(HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_LAUNCHCTL="$box/bin/launchctl" \
    "$box/brew/opt/shrinkit/bin/shrinkit" teardown 2>&1)"

  # setup_bin makes no link under a keg, so naming one here taught anyone reading the output that
  # the list is boilerplate rather than a report.
  check "removes the agent" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "and does not name a PATH entry it never made" lacks "$out" "the PATH link"
  check "nor one under ~/.local at all" lacks "$out" "$box/home/.local/bin"
  check "and leaves brew's own binary alone" exists "$box/brew/Cellar/shrinkit/9.9/bin/shrinkit"
}

test_teardown_with_nothing_installed_says_so() {
  local box out
  box="$(scratch)"
  setup_box "$box"

  out="$(run_teardown "$box" "$box/work" 2>&1)"

  check "reports that there was nothing here" contains "$out" "Nothing to remove"
  check "and still says what it left alone" contains "$out" "$box/work"
}

test_teardown_does_not_report_what_it_could_not_remove() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  # A Desktop that refuses the delete, the way a sandbox or a missing privacy grant does.
  chmod a-w "$box/home/Desktop"

  out="$(run_teardown "$box" 2>&1)"
  chmod u+w "$box/home/Desktop"

  check "the shortcut is still there" test -L "$box/home/Desktop/work"
  check "and the report does not claim it" lacks "$out" "the Desktop shortcut"
  check "but names it as left behind" contains "$out" "Could not remove (delete by hand): $box/home/Desktop/work"
  check "while what it could remove is reported" contains "$out" "the agent"
}

test_teardown_finds_the_folder_it_registered_without_being_told() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/elsewhere" > /dev/null 2>&1
  check "the shortcut is there to begin with" links_to "$box/home/Desktop/elsewhere" "$box/elsewhere"

  # No SHRINKIT_DIR: the plist it is about to delete is the only thing that still knows.
  run_teardown "$box" > /dev/null 2>&1

  check "removes the agent" missing "$box/home/Library/LaunchAgents/com.shrinkit.plist"
  check "boots it out first" grep -q "^bootout gui/$(id -u)/com.shrinkit$" "$box/launchctl.log"
  check "removes the PATH link" missing "$box/home/.local/bin/shrinkit"
  check "removes that folder's Desktop shortcut" missing "$box/home/Desktop/elsewhere"
  check "removes the Finder entries" test "$(action_count "$box/home/Library/Services")" = 0
}

test_teardown_leaves_the_recordings_and_the_settings_alone() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" "$box/elsewhere" > /dev/null 2>&1
  print -r -- "crf = 19" >> "$box/elsewhere/settings.conf"
  cp "$FIXTURES/silent.mov" "$box/elsewhere/input/clip.mov"

  run_teardown "$box" > /dev/null 2>&1

  check "keeps the settings" grep -q "crf = 19" "$box/elsewhere/settings.conf"
  check "keeps what was waiting to be processed" exists "$box/elsewhere/input/clip.mov"
  check "and the presets" exists "$box/elsewhere/presets/2x.conf"
}

test_teardown_never_takes_a_real_folder_off_the_desktop() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  rm -f "$box/home/Desktop/work"
  mkdir -p "$box/home/Desktop/work"

  run_teardown "$box" > /dev/null 2>&1

  check "leaves it where it is" is_dir "$box/home/Desktop/work"
}

# --------------------------------------------------------------------- run them

# Every top-level test_* function, in the order they're defined, so the grouping in this file is
# the grouping that runs. Nothing here to keep in sync by hand when a test is added or renamed.
typeset -a TESTS
TESTS=("${(f)$(grep -oE '^test_[a-zA-Z0-9_]+' "${0:A}")}")

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
