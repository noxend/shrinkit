# Sourced by tests/run-tests.sh: what every test checks with, and the sandboxes it runs in.

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

# Every pic_init_qp_minus26 the file's video carries, in its header and in its stream, one distinct
# value per line: the picture parameter sets a copy join has to keep the same.
pps_values() {
  "$FFMPEG" -nostdin -i "$1" -map 0:v -c copy -bsf:v trace_headers -f null - 2>&1 \
    | awk '/pic_init_qp_minus26/ { print $NF }' | sort -u
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
