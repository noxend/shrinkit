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

# A file, not an array: a sandbox is usually created inside a $(...) capture, which forks a
# subshell, and an array append there would vanish with it. A file write survives.
SANDBOX_MANIFEST="$(mktemp)"

cleanup() {
  local box
  [[ -f "$SANDBOX_MANIFEST" ]] && while IFS= read -r box; do rm -rf "$box"; done < "$SANDBOX_MANIFEST"
  rm -f "$SANDBOX_MANIFEST"
}
trap cleanup EXIT INT TERM

track() {
  print -r -- "$1" >> "$SANDBOX_MANIFEST"
}

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

# A tracked-for-cleanup temp dir.
scratch() {
  local dir
  dir="$(mktemp -d)"
  track "$dir"
  print -r -- "$dir"
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

# Runs the script under test. SHRINKIT_REPO is blank so the update check stays out of it.
optimize() {
  SHRINKIT_DIR="$1" SHRINKIT_REPO="" zsh "$OPTIMIZER"
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
  # 20s, motion only in the first 4, mimicking long pauses for mpdecimate
  make_fixture idle.mov -f lavfi -i "color=c=0x1e1e1e:s=1920x1080:r=60:d=20" \
    -f lavfi -i "testsrc2=s=480x270:r=60:d=4" \
    -filter_complex "[0][1]overlay=60:60:enable='lt(t,4)'" \
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p
  # blue/red/blue/green/blue, 3-1-4-1-3s, a moving overlay in each stretch so trim_idle behaves
  # normally on it. Red 3-4s and green 8-9s stand in for something that must not survive a cut.
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
}

# --------------------------------------------------------------------- the tests

test_basic_encode() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
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
  settings "$box" 'speed = 3' 'remove_audio = false' 'output_suffix = -fast' 'fps = 0'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-fast.mp4"

  check "honours output_suffix" exists "$out"
  check "honours speed 3 on a 12s clip" duration_near "$out" 4
  check "keeps the audio when asked" has_audio "$out"
}

test_basic_suffix_follows_the_speed() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 3'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "names the file after the speed it used" exists "$box/output/clip-3x.mp4"
}

test_trim_idle_cuts_the_pauses_out() {
  local box
  box="$(sandbox)"
  settings "$box" 'trim_idle = true'
  cp "$FIXTURES/idle.mov" "$box/input/clip.mov"

  optimize "$box"
  # 20s in, 4s of it moving, halved by the default 2x speed
  check "keeps only the moving part" duration_near "$box/output/clip-2x.mp4" 2
  check "says so in the log" logged "$box" 'trimmed'
}

test_trim_idle_is_off_unless_asked_for() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  cp "$FIXTURES/idle.mov" "$box/input/clip.mov"

  optimize "$box"
  check "leaves the pauses in" duration_near "$box/output/clip-2x.mp4" 10
}

test_trim_idle_stands_down_when_the_audio_is_kept() {
  local box
  box="$(sandbox)"
  settings "$box" 'trim_idle = true' 'remove_audio = false'
  cp "$FIXTURES/withaudio.mov" "$box/input/clip.mov" # static picture, so trimming would gut it
  local out="$box/output/clip-2x.mp4"

  optimize "$box"
  check "says why it did not trim" logged "$box" 'not trimming'
  check "keeps the untrimmed length" duration_near "$out" 6
  check "and keeps the audio" has_audio "$out"
}

test_downscale() {
  local box
  box="$(sandbox)"
  settings "$box" 'max_height = 720'
  cp "$FIXTURES/tall.mov" "$box/input/clip.mov"

  optimize "$box"
  check "downscales 2160p to 720p" test "$(height_of "$box/output/clip-2x.mp4")" = 720
}

test_keep_original_false_deletes_the_source() {
  local box
  box="$(sandbox)"
  settings "$box" 'keep_original = false'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "still writes the output" exists "$box/output/clip-2x.mp4"
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

test_output_dir_redirect() {
  local box
  box="$(sandbox)"
  settings "$box" "output_dir = $box/elsewhere"
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "writes to the folder we named" exists "$box/elsewhere/clip-2x.mp4"
  check "leaves the default one empty" empty_dir "$box/output"
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
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/big.mov" "$work/clip.mov"
  out="$work/clip-2x.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/clip.mov" > /dev/null 2>&1 &
  sleep 2 # the 4K fixture takes several seconds, so this lands mid-encode

  check "nothing sits at the final name yet" missing "$out"
  check "the half-written file is hidden" test "$(ls -A "$work" | grep -c '\.part\.mp4$')" = 1
  wait

  check "it lands when the encode finishes" exists "$out"
  check "and plays" playable "$out"
  check "leaving no part files behind" test "$(ls -A "$work" | grep -c part)" = 0
}

test_a_broken_line_spoils_only_itself() {
  local box
  box="$(sandbox)"
  settings "$box" 'this line has no equals sign' 'speed = 3' '' '   # an indented comment'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-3x.mp4"

  check "reads the settings around it" exists "$out"
  check "and applies them" duration_near "$out" 4
}

test_an_old_json_config_is_reported() {
  local box
  box="$(sandbox)"
  print '{ "speed": 3 }' > "$box/settings.jsonc"
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --no-notify --no-notify-start
  check "says the format moved on" logged "$box" 'run install.sh to convert it'
  check "and carries on with the defaults" exists "$box/output/clip-2x.mp4"
}

test_cuts_remove_the_marked_ranges() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '3-4' '8-9' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip-1x.mp4"

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
  out="$box/output/clip-1x.mp4"
  check "cuts the same two seconds either way" duration_near "$out" 10
}

test_cuts_keep_kept_audio_in_sync() {
  local box out video_len audio_len
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'remove_audio = false'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- '3-4' '8-9' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip-1x.mp4"
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
  check "keeps the full length" duration_near "$box/output/clip-1x.mp4" 12
}

test_cuts_bad_line_spoils_only_itself() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -rl -- 'not-a-range' '3-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip-1x.mp4"
  check "still applies the good range" duration_near "$out" 11
  check "logs the bad one" logged "$box" "ignoring cut 'not-a-range'"
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

test_cuts_reject_a_range_under_one_frame() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3.001-3.015' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip-1x.mp4"
  check "cuts nothing, the range is under one frame" duration_near "$out" 12
  check "says why in the log" logged "$box" "too short to reliably cut"
  check "does not claim a cut happened" not_logged "$box" ', cut)'
}

test_cuts_that_remove_everything_fail_instead_of_destroying_the_original() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '0-12' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "does not write a broken output" missing "$box/output/clip-1x.mp4"
  check "leaves the original in place" exists "$box/input/clip.mov"
  check "logs it as a failure, not a success" logged "$box" 'FAILED clip.mov'
}

test_cuts_reject_a_malformed_end_like_a_stray_dash() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '3-4-4' > "$box/input/clip.mov.cuts"

  optimize "$box"
  out="$box/output/clip-1x.mp4"
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
  out="$box/output/clip-1x.mp4"
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
  out="$box/output/clip-1x.mp4"
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
  check "says so on the done line" logged "$box" 'done   clip-1x.mp4.*, cut applied'
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
    logged "$box" 'done   clip-1x.mp4.*, cut requested but none applied'
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
  check "still shrinks the file" exists "$box/output/clip-1x.mp4"
}

test_cuts_rich_text_sidecar_is_named_and_refused() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  cp "$FIXTURES/colored.mov" "$box/input/clip.mov"
  print -r -- '{\rtf1\ansi 3-4}' > "$box/input/clip.mov.cuts"

  optimize "$box"
  check "names Rich Text specifically, not a generic parse error" \
    logged "$box" 'Rich Text, not plain text'
  check "keeps the full length" duration_near "$box/output/clip-1x.mp4" 12
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
  out="$box/output/clip-1x.mp4"
  check "still cuts it, spaces and all" duration_near "$out" 11
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
    'output_suffix = ' 'keep_days = never'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local key
  for key in speed fps crf codec remove_audio output_suffix keep_days; do
    check "rejects a bad $key" logged "$box" "ignoring $key="
  done
  check "still encodes on the defaults" exists "$box/output/clip-2x.mp4"
}

test_unknown_settings_are_ignored() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'there_is_no_such_setting = hello'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "a stray key does no harm" exists "$box/output/clip-2x.mp4"
}

test_a_hash_inside_a_value_is_kept() {
  local box
  box="$(sandbox)"
  # only a whole comment line starts with #, so one in the middle of a value is just text
  settings "$box" 'speed = 3' 'output_suffix = -2x#a'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  local out="$box/output/clip-2x#a.mp4"

  check "keeps the # in the value" exists "$out"
  check "and the rest of the config still lands" duration_near "$out" 4
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
  settings "$box" 'speed = 2'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"
  plant_lock "$box" "$(dead_pid)"

  optimize "$box"
  check "takes the abandoned lock over" exists "$box/output/clip-2x.mp4"
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

  check "finishes the first" exists "$box/output/first-2x.mp4"
  check "catches the late arrival too" exists "$box/output/second-2x.mp4"
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
  check "still handles the good one" exists "$box/output/good-2x.mp4"
}

test_one_shot_optimizes_a_file_in_place() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  # a file living outside the input folder, like something you right-click in Finder
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov"

  check "writes the result next to the source" exists "$work/recording-2x.mp4"
  check "leaves the original in place" exists "$work/recording.mov"
  check "halves the duration" duration_near "$work/recording-2x.mp4" 6
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
  check "optimizes the first" exists "$work/a-2x.mp4"
  check "optimizes the second" exists "$work/b-2x.mp4"
}

test_one_shot_skips_a_cuts_sidecar_selected_alongside_the_video() {
  local box work
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  work="$(scratch)"
  cp "$FIXTURES/silent.mov" "$work/recording.mov"
  print -r -- '1-2' > "$work/recording.mov.cuts"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" "$work/recording.mov" "$work/recording.mov.cuts"

  check "shrinks the video" exists "$work/recording-2x.mp4"
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
  out="$work/clip-4x.mp4"

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

test_config_show_lists_what_is_in_effect() {
  local box out
  box="$(sandbox)"
  settings "$box" 'crf = 31'

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config)"
  check "reports the value from the file" grep -q '^crf = 31$' <<< "$out"
  check "and a setting the file never named" grep -q '^codec = h264$' <<< "$out"
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

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config trim-idle true > /dev/null
  check "adds it under its real name" grep -q '^trim_idle = true$' "$box/settings.conf"
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

  check "takes the settings from the preset" exists "$work/clip-3x.mp4"
  check "and the length that goes with them" duration_near "$work/clip-3x.mp4" 4
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

  check "the flag wins" exists "$work/clip-4x.mp4"
}

test_preset_list_names_what_is_there() {
  local box out
  box="$(sandbox)"
  settings "$box" 'speed = 2'
  preset "$box" chat 'speed = 3'
  preset "$box" tiny 'crf = 34'

  out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" preset list)"
  check "lists both" test "$out" = "chat
tiny"
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

  # the same for the Quick Action side, which must not write into ~/Library/Services
  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" preset install nope > /dev/null 2>&1 || code=$?
  check "refuses to build an action for it" test "$code" = 2
  check "and builds nothing" missing "$HOME/Library/Services/shrinkit: nope.workflow"
}

test_notify_start_does_not_break_the_run() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify_start = true'
  cp "$FIXTURES/silent.mov" "$box/input/clip.mov"

  optimize "$box"
  check "the run still completes with notify_start on" exists "$box/output/clip-2x.mp4"
}

# --------------------------------------------------------------------- run them

TESTS=(
  test_basic_encode
  test_basic_settings_are_used
  test_basic_suffix_follows_the_speed
  test_trim_idle_cuts_the_pauses_out
  test_trim_idle_is_off_unless_asked_for
  test_trim_idle_stands_down_when_the_audio_is_kept
  test_downscale
  test_keep_original_false_deletes_the_source
  test_keep_days_prunes_old_originals
  test_keep_days_counts_from_archiving_not_the_recording_date
  test_keep_days_too_large_is_rejected_not_truncated
  test_keep_days_does_not_claim_a_removal_that_failed
  test_keep_days_off_by_default
  test_output_dir_redirect
  test_skips_work_already_done
  test_ignores_things_that_are_not_videos
  test_the_output_appears_only_once_it_is_finished
  test_a_broken_line_spoils_only_itself
  test_an_old_json_config_is_reported
  test_cuts_remove_the_marked_ranges
  test_cuts_accept_the_mm_ss_format
  test_cuts_keep_kept_audio_in_sync
  test_cuts_are_skipped_with_no_sidecar_file
  test_cuts_bad_line_spoils_only_itself
  test_cuts_sidecar_is_archived_with_the_original
  test_cuts_sidecar_is_deleted_with_the_original
  test_cuts_reject_a_range_under_one_frame
  test_cuts_that_remove_everything_fail_instead_of_destroying_the_original
  test_cuts_reject_a_malformed_end_like_a_stray_dash
  test_cuts_unreadable_sidecar_is_logged_and_skipped
  test_cuts_without_a_trailing_newline_still_applies
  test_cuts_long_bad_line_is_truncated_in_the_log
  test_cuts_note_says_applied_when_a_cut_took
  test_cuts_note_is_silent_with_no_sidecar
  test_cuts_note_warns_when_every_line_was_rejected
  test_cuts_near_miss_filename_is_warned_about
  test_cuts_rich_text_sidecar_is_named_and_refused
  test_cuts_smart_dash_is_named_specifically
  test_cuts_trims_whitespace_around_the_dash
  test_mark_cuts_with_no_files_is_refused
  test_bad_values_are_rejected_one_by_one
  test_unknown_settings_are_ignored
  test_a_hash_inside_a_value_is_kept
  test_lock_keeps_two_runs_apart
  test_a_lock_from_a_dead_run_is_taken_over
  test_a_lock_from_a_live_run_is_left_alone
  test_picks_up_a_file_dropped_mid_run
  test_a_broken_file_does_not_wedge_the_queue
  test_one_shot_optimizes_a_file_in_place
  test_one_shot_handles_several_files
  test_one_shot_skips_a_cuts_sidecar_selected_alongside_the_video
  test_flags_are_answered_not_swallowed
  test_flags_beat_the_config_file
  test_flags_that_make_no_sense_are_refused
  test_config_show_lists_what_is_in_effect
  test_config_set_edits_the_line_in_place
  test_config_set_appends_a_setting_that_was_missing
  test_config_set_refuses_a_setting_that_does_not_exist
  test_preset_is_read_on_top_of_the_config
  test_preset_loses_to_a_flag
  test_preset_list_names_what_is_there
  test_preset_that_does_not_exist_is_refused
  test_notify_start_does_not_break_the_run
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
