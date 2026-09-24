#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- the screen of a run

# What a run shows on its terminal: a line per step under a coloured word, and a bar or a spinner
# while ffmpeg works on one.

# The escape codes a run's screen is drawn with: bold, dim and the 8 basic colours, which follow
# the terminal's theme. Every one is empty unless stdout is a terminal and NO_COLOR is not set
# (no-color.org), and the words are the same either way. Decided once, as the file is sourced: a
# run writes to the stdout the process started with.
typeset -A PAINT
paint_screen() {
  PAINT=(bold '' dim '' reset '' red '' green '' yellow '' magenta '' cyan '')
  [[ -t 1 && -z "${NO_COLOR-}" ]] || return 0
  PAINT=(bold $'\e[1m' dim $'\e[2m' reset $'\e[0m' red $'\e[31m' green $'\e[32m' yellow $'\e[33m'
    magenta $'\e[35m' cyan $'\e[36m')
}
paint_screen

# The colour of each word a step goes under.
typeset -A WORD_COLOUR
WORD_COLOUR=(encoding cyan joining magenta done green joined magenta failed red skipped yellow
  note yellow)

# How many steps a run has said, so it knows whether anything was said before its first
# recording. While SCREEN_HOLD is 1 they wait in SCREEN_HELD for the lines that head the run.
SCREEN_LINES=0
SCREEN_HOLD=0
typeset -a SCREEN_HELD

# screen_line <word> <text>: one step on the screen, its word in a column of 9 after 6 spaces, so
# the text of every step lines up.
screen_line() {
  local line="      ${PAINT[${WORD_COLOUR[$1]}]}${(r:9:)1}${PAINT[reset]} $2"
  ((++SCREEN_LINES))
  if ((SCREEN_HOLD)); then
    SCREEN_HELD+=("$line")
  else
    print -r -u "${SCREEN_FD:-1}" -- "$line"
  fi
}

# A line log() writes during a run, on the screen under the word for what it says, anything else
# as a note. The filter graph is for reading a cut back in the log; ffmpeg's own output and mv's
# reason are only in the log, so the screen names the log for them. A result goes by its sizes
# alone, since in a merged run its name is a part in the temporary folder.
screen_log() {
  local line="$1" word=note
  local -a match mbegin mend
  case "$line" in
    graph\ *) return 0 ;;
    # On a terminal run_ffmpeg draws the encode as it goes instead.
    encode\ *)
      screen_draws && return 0
      word=encoding
      ;;
    done\ *) word=done ;;
    merged\ *) word=joined ;;
    FAILED\ *) word=failed ;;
    ignoring\ * | skip\ *) word=skipped ;;
  esac
  [[ "$word" == note ]] || line="${${line#* }##[[:space:]]#}"
  [[ "$word" == done && "$line" =~ ' \(([^ ()]+ -> [^ ()]+)\)([^()]*)$' ]] \
    && line="${match[1]}${match[2]}"
  line="${line//ffmpeg output is above/ffmpeg output is in $LOG}"
  screen_line "$word" "${line//the reason is (on the line |)above/the reason is in $LOG}"
}

# Whether the screen shows a step while ffmpeg works on it: during a run, on a terminal, in colour.
screen_draws() {
  [[ -n "$SCREEN_FD" && -n "${PAINT[reset]}" ]]
}

# The progress file of the step being drawn, until it ends.
SCREEN_PROGRESS=""

# screen_progress <word> <seconds> <progress file>: while ffmpeg (CURRENT_CHILD) runs, its step
# redrawn in place 10 times a second, with the cursor hidden: a bar of 30 cells, fewer on a narrow
# terminal, for ffmpeg's out_time against the seconds the result lasts, then the percent and, past
# 3%, the time left; a spinner instead when the seconds are not known. The line is cleared at the
# end, for the step's result to take its place.
screen_progress() {
  local word="$1" length="$2" fd line partial="" us=0 k=0 started
  zmodload zsh/datetime zsh/zselect
  started=$EPOCHREALTIME
  [[ -n "$length" ]] && ((length > 0)) || length=""
  SCREEN_PROGRESS="$3"
  exec {fd}< "$3"
  print -rn -u "$SCREEN_FD" -- $'\e[?25l'
  while kill -0 "$CURRENT_CHILD" 2> /dev/null; do
    # ffmpeg adds a block of key=value lines at a time; a line not yet written whole waits for
    # the rest of it.
    while IFS= read -r -u "$fd" line; do
      line="$partial$line"
      partial=""
      [[ "$line" =~ ^out_time_us=([0-9]+)$ ]] && us="${match[1]}"
    done
    partial="$partial$line"
    if [[ -n "$length" ]]; then
      screen_bar "$word" "$us" "$length" "$started"
    else
      screen_spinner "$word" $((k++))
    fi
    zselect -t 10
  done
  exec {fd}<&-
  screen_stop
}

# M:SS, as a player shows it. Whole seconds, rounded down.
minutes() {
  local secs="${1%.*}"
  printf '%d:%02d' $((secs / 60)) $((secs % 60))
}

# The columns a line redrawn in place may take: one fewer than the terminal is wide, so writing the
# last of them never leaves the cursor waiting to wrap. Nothing when the terminal does not say.
# Asked at every draw, since the window may be resized during a step, and of the terminal itself:
# COLUMNS follows a resize only while stdin is that terminal too.
screen_room() {
  local size
  size="$(stty size <&$SCREEN_FD 2> /dev/null)"
  size="${size#* }"
  [[ "$size" =~ ^[0-9]{1,4}$ ]] && ((size > 0)) && print -r -- $((size - 1))
}

# screen_bar <word> <microseconds done> <seconds in all> <when it started>: the line fitted to the
# terminal, since a line that wraps leaves a copy of itself at every redraw. The bar gives up cells
# first, down to 10, then the time left goes and the bar takes what room is left; where not even
# the word and the percent fit, nothing is drawn.
screen_bar() {
  local word="$1" colour="${PAINT[${WORD_COLOUR[$1]}]}" filled="" rest="" left="" line room i
  local -F part elapsed
  local -i pct width cells secs
  part=$(($2 / ($3 * 1000000.0)))
  ((part > 1)) && part=1
  pct=$((part * 100))
  if ((pct > 3)); then
    elapsed=$((EPOCHREALTIME - $4))
    secs=$((elapsed * (1 - part) / part))
    ((secs < 60)) && left="${secs}s left" || left="$(minutes $secs) left"
  fi
  # Around the bar: 16 columns for the indent and the word, 5 for the percent, and two spaces and
  # the time left.
  width=30
  room="$(screen_room)"
  if [[ -n "$room" ]]; then
    width=$((room - 21 - (${#left} ? ${#left} + 2 : 0)))
    if ((width < 10)) && [[ -n "$left" ]]; then
      left=""
      width=$((room - 21))
    fi
    ((width < 0)) && return 0
    ((width > 30)) && width=30
  fi
  cells=$((part * width))
  # One cell at a time, so the bar is the same whatever the locale says a character is.
  for ((i = 0; i < width; i++)); do
    ((i < cells)) && filled="$filled━" || rest="$rest━"
  done
  line="      $colour${(r:9:)word}${PAINT[reset]} $colour$filled${PAINT[dim]}$rest${PAINT[reset]}"
  line="$line ${(l:3:)pct}%${left:+  ${PAINT[dim]}$left${PAINT[reset]}}"
  print -rn -u "$SCREEN_FD" -- $'\r'"$line"$'\e[K'
}

# The frames of the spinner a step of unknown length shows: braille, which is text, not emoji.
SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# screen_spinner <word> <frame>: nothing where the word and the frame, 17 columns, do not fit.
screen_spinner() {
  local colour="${PAINT[${WORD_COLOUR[$1]}]}" line room
  room="$(screen_room)"
  [[ -z "$room" ]] || ((room >= 17)) || return 0
  line="      $colour${(r:9:)1}${PAINT[reset]} $colour${SPINNER[$2 % 10 + 1]}${PAINT[reset]}"
  print -rn -u "$SCREEN_FD" -- $'\r'"$line"$'\e[K'
}

# The step's line cleared, the cursor shown again and the progress file removed: when the step
# ends, and from the EXIT trap when a signal ends the run during one.
screen_stop() {
  [[ -n "$SCREEN_PROGRESS" ]] || return 0
  print -rn -u "$SCREEN_FD" -- $'\r\e[K\e[?25h'
  rm -f "$SCREEN_PROGRESS"
  SCREEN_PROGRESS=""
}
