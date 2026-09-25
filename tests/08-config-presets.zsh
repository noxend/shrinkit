# Sourced by tests/run-tests.sh: the config and preset subcommands.

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
  settings "$box" 'crf = 31' 'fps = 30' 'max_height = 720'

  # zsh truncates a digit string past 19 places to something negative, so a bare <= comparison
  # passes it and prints its own diagnostic doing so. Both reached the user: the command reported
  # success on a value no run can use, with "number truncated after 19 digits" above it.
  for key in crf fps max_height; do
    code=0
    out="$(SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
      zsh "$OPTIMIZER" config "$key" 99999999999999999999 2>&1)" || code=$?
    check "$key stops rather than writing it" test "$code" = 2
    check "and leaks no zsh diagnostic" lacks "$out" "truncated"
  done
  check "the file keeps the value it had" grep -q '^crf = 31$' "$box/settings.conf"
  check "and the other ones too" grep -q '^fps = 30$' "$box/settings.conf"
  check "all of them" grep -q '^max_height = 720$' "$box/settings.conf"
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

# What a run ends up using, read the way "config" shows it.
in_effect() {
  SHRINKIT_DIR="$1" SHRINKIT_REPO="" zsh "$OPTIMIZER" config 2> /dev/null
}

test_a_last_line_with_no_line_break_is_read() {
  local box
  box="$(sandbox)"
  settings "$box" 'speed = 3'
  printf 'crf = 20' >> "$box/settings.conf" # nothing typed after the last setting

  check "takes the last setting" contains "$(in_effect "$box")" "crf = 20"
}

test_a_setting_without_an_equals_sign_is_logged() {
  local box
  box="$(sandbox)"
  settings "$box" 'crf: 40'

  in_effect "$box" > /dev/null

  check "names the line and what is wrong with it" \
    logged "$box" "ignoring settings.conf line 2: 'crf: 40' has no '='"
}

test_a_byte_order_mark_does_not_hide_the_first_setting() {
  local box
  box="$(sandbox)"
  # What an editor saving "UTF-8 with BOM" puts in front of the first line.
  { printf '\xef\xbb\xbf' && print -rl -- 'crf = 20' 'notify = false'; } > "$box/settings.conf"

  check "reads the first line as written" contains "$(in_effect "$box")" "crf = 20"
  check "and logs nothing about it" not_logged "$box" "not a setting"
}

test_config_set_keeps_a_last_line_with_no_line_break() {
  local box
  box="$(sandbox)"
  print -rl -- 'crf = 28' > "$box/settings.conf"
  printf 'speed = 3' >> "$box/settings.conf"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" config crf 30 > /dev/null

  check "keeps it" grep -q '^speed = 3$' "$box/settings.conf"
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

test_a_part_that_cannot_be_read_stops_the_run_and_says_so() {
  local box out code
  box="$(scratch)"
  brew_cask "$box"
  rm -f "$box/brew/Caskroom/shrnkit/9.9/shrinkit-9.9/lib/merge.zsh"

  code=0
  out="$(HOME="$box/home" SHRINKIT_DIR="$box" "$box/brew/bin/shrinkit" --help 2>&1)" || code=$?

  # A packaging mistake, not a missing feature: carrying on would fail later somewhere that reads
  # as a bug in whatever the user was actually doing.
  check "stops rather than running without it" test "$code" = 1
  check "and names the file it could not read" contains "$out" "merge.zsh"
}

# A preset whose every line is a comment changes nothing, which a right-click run would show only as a
# result no different from settings.conf's.
test_a_preset_that_sets_nothing_says_so() {
  local box tools out
  box="$(sandbox)"
  settings "$box" 'speed = 2' 'notify = true'
  mkdir -p "$box/presets"
  print -rl -- '# a preset' '# max_height = 320' '' > "$box/presets/320p.conf"
  cp "$FIXTURES/silent.mov" "$box/clip.mov"
  tools="$(scratch)"
  stub_tools "$tools"

  out="$(PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --preset 320p "$box/clip.mov" 2>&1)"

  check "says so on the terminal" contains "$out" "the preset '320p' sets nothing: take the # off the lines"
  check "and in the log" grep -qF "the preset '320p' sets nothing" "$box/.logs/optimizer.log"
  check "and in a banner" grep -qF "banner shrinkit | The preset '320p' sets nothing" "$tools/osascript.log"
  check "and still runs with settings.conf" exists "$box/clip-320p.mp4"
}
