# Sourced by tests/run-tests.sh: the --cut flag.

test_cut_flag_cuts_the_range_it_was_given() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 "$work/clip.mov"

  check "cuts the range it was given" duration_near "$out" 11
  check "and says so on the done line" logged "$box" 'done   clip.mp4.*, cut applied'
}

test_cut_flag_sorts_and_merges_its_ranges() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  # out of order, and the last one inside the one before it
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut 8-9 --cut 3-6 --cut 4-5 "$work/clip.mov"

  check "merges the overlap and keeps the separate range" duration_near "$out" 8
}

test_cut_flag_reaches_the_real_end() {
  local box work out
  box="$(sandbox)"
  settings "$box" 'speed = 1'
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  out="$work/clip.mp4"

  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 9-end "$work/clip.mov"

  check "'end' means the real length here too" duration_near "$out" 9
}

# --cut with the filename forgotten used to fall through to folder-watch mode, cutting the same
# seconds out of every queued recording, and with keep_original = false deleting each source it had
# just cut.
test_cut_flag_with_no_file_is_refused() {
  local box code
  box="$(sandbox)"
  settings "$box" 'speed = 1' 'keep_original = false'
  cp "$FIXTURES/colored.mov" "$box/input/queued.mov"

  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" --cut 3-4 > /dev/null 2>&1 || code=$?

  check "stops with a usage error" test "$code" = 2
  check "leaves the queued recording alone" exists "$box/input/queued.mov"
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
  # Letting it through would shrink the recording without the range that was meant.
  work="$(scratch)"
  cp "$FIXTURES/colored.mov" "$work/clip.mov"
  code=0
  SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" --cut '' "$work/clip.mov" > /dev/null 2>&1 || code=$?

  check "an empty range is refused too" test "$code" = 2
  check "and without writing an output" missing "$work/clip.mp4"
}

# zsh expands a whole `local` line before any of its names becomes local, so a second assignment
# on that line that reads the first gets the CALLER's variable of that name, silently, or aborts
# the function under set -u when the caller has none. Proved, not reasoned:
#   zsh -c 'set -u; src=/OUTER; f() { local src="$1" out="${src}.mp4"; print $out }; f /ARG'
# prints /OUTER.mp4. The three places shrinkit.sh had all worked only because every caller happened
# to have the same variable set to the same value, which the next caller has no reason to.
test_no_local_line_reads_a_name_it_declares() {
  local -a lines names
  local line name bad=""
  lines=("${(@f)$(grep -n '^[[:space:]]*local .*=' "$OPTIMIZER" "$REPO_DIR"/lib/*.zsh)}")
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
