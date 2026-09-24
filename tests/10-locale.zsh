# Sourced by tests/run-tests.sh: a comma decimal locale.

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
