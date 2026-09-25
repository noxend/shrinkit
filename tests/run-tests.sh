#!/bin/zsh
#
# Test suite for the optimizer. Every test runs the real script against a throwaway folder under
# /tmp, so your own recordings are never touched and the launchd agent is not involved.
#
#   ./tests/run-tests.sh            run everything
#   ./tests/run-tests.sh basic      run only the tests whose name contains "basic"
#
# The tests are in tests/NN-<area>.zsh, their helpers in tests/lib/.
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

# A launchctl call that no test pointed at its own stub lands here, not on the real launchctl, which
# would boot out the agent in use on this Mac. The stubs sit where an empty sandbox path names
# nothing: "$box/stub/launchctl" with no box is /stub/launchctl.
mkdir -p "$TMPROOT/refuse"
print -rl -- '#!/bin/zsh' 'print -u2 -r -- "a test reached launchctl without its stub: $*"' 'exit 99' \
  > "$TMPROOT/refuse/launchctl"
chmod +x "$TMPROOT/refuse/launchctl"
export SHRINKIT_LAUNCHCTL="$TMPROOT/refuse/launchctl"

# pbs is kept off the real one too, or every setup and teardown test would refresh the Services menu
# of this Mac. A no-op rather than a refusal: every caller ignores how pbs answers, so a refusal
# would never be seen.
mkdir -p "$TMPROOT/stub"
print -rl -- '#!/bin/zsh' 'exit 0' > "$TMPROOT/stub/pbs"
chmod +x "$TMPROOT/stub/pbs"
export SHRINKIT_PBS="$TMPROOT/stub/pbs"

# An editor of this machine's own would open for real where a test names none, or win over the one
# it names: VISUAL outranks EDITOR.
unset VISUAL EDITOR

# open and osascript are reached through the PATH, so a test without stubs of its own finds these
# first, not the ones that would open windows and post banners on this Mac. Each call is written
# down as well, since every banner throws away what osascript says, and the test that made it fails.
mkdir -p "$TMPROOT/refuse-bin"
for _tool in open osascript; do
  print -rl -- '#!/bin/zsh' "print -r -- \"$_tool \$*\" >> ${(qq)TMPROOT}/refused" \
    "print -u2 -r -- \"a test reached $_tool without its stub: \$*\"" 'exit 99' > "$TMPROOT/refuse-bin/$_tool"
  chmod +x "$TMPROOT/refuse-bin/$_tool"
done
unset _tool
export PATH="$TMPROOT/refuse-bin:$PATH"

# A sandbox is a folder under TMPROOT; anything else stops the run before it is used.
sandboxed() {
  [[ "$1" == "$TMPROOT"/?* ]] || {
    print -r -- "not a test sandbox: '$1'"
    exit 1
  }
}

# The helpers first, then the tests: one file per area, sourced and run in file-name order.
for _file in "$TESTS_DIR"/lib/*.zsh; do source "$_file"; done
TEST_FILES=("$TESTS_DIR"/[0-9][0-9]-*.zsh)
# A file that does not parse would load only the tests above the error and drop the rest without a
# word, so each is parsed before any is loaded.
for _file in "$TESTS_DIR"/lib/*.zsh "${TEST_FILES[@]}"; do
  zsh -n "$_file" || {
    print -r -- "tests/${_file#$TESTS_DIR/} does not parse; nothing was run"
    exit 1
  }
done
for _file in "${TEST_FILES[@]}"; do source "$_file"; done
unset _file

# --------------------------------------------------------------------- run them

# Every top-level test_* function, file by file in the order each defines them, so the grouping
# on disk is the grouping that runs. Nothing here to keep in sync by hand when a test is added or
# renamed.
typeset -a TESTS
TESTS=("${(f)$(grep -hoE '^test_[a-zA-Z0-9_]+' "${TEST_FILES[@]}")}")

# Every file is sourced into this one shell, so a function defined twice, a test or a helper, in
# one file or in two, keeps only its later body, and a test would run it twice or call the wrong
# helper: that stops the run instead. A name inside a heredoc counts too (the stub editor's in
# tests/lib/edit.zsh), a false alarm at worst.
TWICE="$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$TESTS_DIR"/lib/*.zsh "${TEST_FILES[@]}" | sort | uniq -d)"
[[ -z "$TWICE" ]] || {
  print -r -- "defined twice: ${${TWICE//\(\)/}//$'\n'/, }"
  exit 1
}

print "building sample videos in tests/fixtures (first run only)"
build_fixtures
print ""

CURRENT_TEST=""
typeset -i RAN=0 _checks _status
for CURRENT_TEST in "${TESTS[@]}"; do
  [[ -n "$FILTER" && "$CURRENT_TEST" != *"$FILTER"* ]] && continue
  print "${CURRENT_TEST#test_}"
  _checks=$((PASSED + FAILED))
  "$CURRENT_TEST"
  _status=$?
  # A test that ran a command that does not exist, or checked nothing, proves nothing.
  ((_status == 127)) && fail "a command it runs was not found"
  ((PASSED + FAILED == _checks)) && fail "it made no check"
  [[ -s "$TMPROOT/refused" ]] && {
    fail "reached $(head -1 "$TMPROOT/refused") without a stub"
    : > "$TMPROOT/refused"
  }
  RAN=RAN+1
done

# A filter that matches no test would otherwise print "0 checks passed" and exit 0.
((RAN > 0)) || {
  print "no test name contains '$FILTER'"
  exit 1
}

print ""
if ((FAILED == 0)); then
  print "$PASSED checks passed"
else
  print "$PASSED passed, $FAILED failed:"
  printf '  %s\n' "${FAILURES[@]}"
fi
exit $((FAILED > 0))
