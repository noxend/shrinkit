# Sourced by tests/run-tests.sh: doctor's ffmpeg check.

test_doctor_fails_when_ffmpeg_was_uninstalled() {
  local box before out code=0
  box="$(installed_box)"
  own_ffmpeg "$box"
  before="$(run_doctor "$box" SHRINKIT_TOOL_DIRS="$box/tools" 2>&1)"
  rm -f "$box/tools/ffmpeg" "$box/tools/ffprobe" # what brew uninstall ffmpeg leaves

  out="$(run_doctor "$box" SHRINKIT_TOOL_DIRS="$box/tools" 2>&1)" || code=$?

  check "found it before" test "$(doctor_line "$before" ffmpeg)" = "ok    ffmpeg         $box/tools/ffmpeg"
  check "fails once it is gone" \
    test "$(doctor_line "$out" ffmpeg)" = "FAIL  ffmpeg         ffmpeg and ffprobe not found where shrinkit looks"
  check "says where it looked" contains "$(doctor_block "$out" ffmpeg)" "$box/tools"
  check "and how to install it" contains "$(doctor_block "$out" ffmpeg)" "  brew install ffmpeg"
  check "counts it as a problem" test "${${(f)out}[-1]}" = "1 problem."
  check "and exits 1" test "$code" = 1
}

test_doctor_fails_when_ffprobe_alone_is_missing() {
  local box out
  box="$(installed_box)"
  own_ffmpeg "$box"
  rm -f "$box/tools/ffprobe"

  out="$(run_doctor "$box" SHRINKIT_TOOL_DIRS="$box/tools" 2>&1)"

  check "fails, naming ffprobe" \
    test "$(doctor_line "$out" ffmpeg)" = "FAIL  ffmpeg         ffprobe not found where shrinkit looks"
}

test_doctor_fails_when_ffmpeg_does_not_run() {
  local box out
  box="$(installed_box)"
  own_ffmpeg "$box"
  # A damaged binary: macOS kills it before it prints a word.
  rm -f "$box/tools/ffmpeg"
  head -c 8192 "${FFMPEG:A}" > "$box/tools/ffmpeg"
  chmod +x "$box/tools/ffmpeg"

  out="$(run_doctor "$box" SHRINKIT_TOOL_DIRS="$box/tools" 2>&1)"

  check "fails, saying it does not run" contains "$(doctor_line "$out" ffmpeg)" "$box/tools/ffmpeg does not run"
  check "and how to reinstall it" contains "$(doctor_block "$out" ffmpeg)" "  brew reinstall ffmpeg"
}

test_doctor_fails_an_ffmpeg_only_the_watchers_path_reaches() {
  local box out
  box="$(scratch)"
  setup_box "$box"
  own_ffmpeg "$box"
  # setup finds this ffmpeg first and writes its folder into the agent's PATH; a right-click entry
  # gets no such PATH, so it looks only where shrinkit looks by itself.
  HOME="$box/home" PATH="$box/tools:$PATH" SHRINKIT_DIR="$box/work" \
    SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" setup > /dev/null 2>&1

  out="$(run_doctor "$box" SHRINKIT_TOOL_DIRS="$box/none" 2>&1)"

  check "fails" verdict_is "$out" ffmpeg FAIL
  check "saying the right-click entries cannot find it" \
    contains "$(doctor_block "$out" ffmpeg)" "the right-click entries do not"
}
