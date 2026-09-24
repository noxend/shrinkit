# Sourced by tests/run-tests.sh: the sample videos, built on the first run.

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
