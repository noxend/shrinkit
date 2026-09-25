#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- the edit file

recordings() {
  (($1 == 1)) && print -r -- "1 recording" || print -r -- "$1 recordings"
}

# M:SS, as a player shows it. Whole seconds, rounded down.
minutes() {
  local secs="${1%.*}"
  printf '%d:%02d' $((secs / 60)) $((secs % 60))
}

# The edit file of a set of recordings, given in merge order: shrinkit-<code>.edit.txt, <code> the
# first 6 hex digits of the SHA-256 of their paths with links resolved, one per line in byte order
# whatever the locale, so a set has one name however its recordings were selected or reached. The
# file an earlier edit left in any of their folders, else a new one beside the first: recordings
# from two folders recorded in the same second come first in the order they were selected in.
edit_file_for() {
  local sum folder name
  sum="$(print -rl -- ${^@:A} | LC_ALL=C sort | shasum -a 256)"
  name="shrinkit-${sum[1,6]}.edit.txt"
  for folder in ${(u)@:h}; do
    [[ -e "$folder/$name" ]] && {
      print -r -- "$folder/$name"
      return
    }
  done
  print -r -- "${1:h}/$name"
}

# write_edit_file <file> <how to run it> <recording>...: one block per recording, in the order
# given, under a header that says what goes in a block. A recording beside the file is named by its
# name, any other by its path.
write_edit_file() {
  local file="$1" how="$2" src name dur list="no presets yet"
  shift 2
  local -a presets
  presets=("$PRESET_DIR"/*.conf(N:t:r))
  ((${#presets})) && list="one of: ${(j:, :)presets}"
  # The outer braces take the shell's own message about a folder it cannot write in: the caller
  # says it in its own words.
  {
    {
      print -r -- "# shrinkit edit: $(recordings $#). $how"
      print -r -- "# One block per recording, run in this order. Delete a block to leave that recording out."
      print -r -- "#"
      print -r -- "# In a block, one setting per line:"
      print -r -- "#   preset = sharp       $list"
      print -r -- "#   cut = 0:32-0:35      a stretch to cut out, one per line; 0-0:20 is the first 20 seconds,"
      print -r -- "#                        2:30-end is everything from 2:30"
      print -r -- "#   keep = 0:10-0:40     the stretch to keep instead; a block uses cut or keep, not both"
      print -r -- "#   speed = 3            also fps, crf, codec, remove_audio, max_height, as in settings.conf"
      print -r -- "#"
      print -r -- "# merge = true joins the results into one video, in the order of the blocks. The first"
      print -r -- "# block's codec, fps and max_height then apply to every recording."
      print
      print -r -- "merge = false"
      for src in "$@"; do
        print
        [[ "${src:h}" == "${file:h}" ]] && name="${src:t}" || name="$src"
        print -r -- "[$name]"
        dur="$(clip_duration "$src")"
        if [[ -n "$dur" ]]; then print -r -- "# ${src:t} is $(minutes "$dur") long"; fi
      done
    } > "$file"
  } 2> /dev/null
}

# --------------------------------------------------------------------- reading it

# What read_edit_file found: merge from above the first block, each block's name as its header
# gives it, the setting lines of every block that can be used, one entry per line across three
# arrays, and a sentence for each line that cannot. EDIT_RTF is 1 for a file saved as rich text.
EDIT_MERGE=false
EDIT_RTF=0
typeset -a EDIT_NAMES EDIT_BLOCK EDIT_KEY EDIT_VALUE EDIT_PROBLEMS

# settings.conf keys that mean nothing for one recording: the first two act only in the watch
# folder, the rest on the run as a whole.
EDIT_RUN_KEYS=(keep_original keep_days notify notify_start notify_sound copy_to_clipboard)

# Why a block's line cannot be used, or nothing when it can.
edit_line_problem() {
  local key="$1" value="$2" reason
  case "$key" in
    merge)
      print -r -- "merge goes above the first recording"
      return 1
      ;;
    preset | cut | keep) ;;
    *)
      [[ -n "${DEFAULTS[$key]+known}" ]] || {
        print -r -- "'$key' is not a setting"
        return 1
      }
      ((${EDIT_RUN_KEYS[(Ie)$key]})) && {
        print -r -- "$key applies to the whole run; set it in settings.conf"
        return 1
      }
      ;;
  esac
  [[ -n "$value" ]] || {
    print -r -- "'$key' has no value"
    return 1
  }
  case "$key" in
    preset)
      [[ -f "$(preset_file "$value")" ]] || {
        print -r -- "no preset called '$value' (looked in $PRESET_DIR)"
        return 1
      }
      ;;
    cut | keep) ;;
    *)
      reason="$(check_setting "$key" "$value")" || {
        print -r -- "$key = $value ($reason)"
        return 1
      }
      ;;
  esac
}

# The rules read_settings has for settings.conf, plus the [headers]. A key is read whatever its
# case and with '-' for '_', since TextEdit capitalises a line and a flag spells it with '-'.
read_edit_file() {
  local line key value problem n=0 block=0
  EDIT_MERGE=false
  EDIT_RTF=0
  EDIT_NAMES=() EDIT_BLOCK=() EDIT_KEY=() EDIT_VALUE=() EDIT_PROBLEMS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++n))
    if ((n == 1)); then
      line="${line#$'\xef\xbb\xbf'}"
      [[ "$line" == '{\rtf'* ]] && {
        EDIT_RTF=1
        return
      }
    fi
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == '#'* ]] && continue
    # From the first [ to the last ], so a name that holds brackets reads right.
    if [[ "$line" == '['*']' ]]; then
      EDIT_NAMES+=("$(trim "${${line#\[}%\]*}")")
      block=${#EDIT_NAMES}
      continue
    fi
    [[ "$line" == *=* ]] || {
      EDIT_PROBLEMS+=("line $n: '$line' has no '='")
      continue
    }
    key="${line%%=*}"
    key="${${(L)key//[[:space:]]/}//-/_}"
    value="$(trim "${line#*=}")"
    value="${value//\"/}"
    case "$key" in
      # A range never holds a #, and a note after one was allowed in the sidecar the edit file
      # replaced.
      cut | keep) value="$(trim "${value%% \#*}")" ;;
      codec | remove_audio | merge) value="${(L)value}" ;;
    esac
    if ((block == 0)); then
      if [[ "$key" != merge ]]; then
        EDIT_PROBLEMS+=("line $n: only merge goes above the first recording")
      elif [[ -z "$value" ]]; then
        EDIT_PROBLEMS+=("line $n: 'merge' has no value")
      elif [[ "$value" == (true|false) ]]; then
        EDIT_MERGE="$value"
      else
        EDIT_PROBLEMS+=("line $n: merge = $value (want true or false)")
      fi
      continue
    fi
    problem="$(edit_line_problem "$key" "$value")" || {
      EDIT_PROBLEMS+=("line $n: $problem")
      continue
    }
    EDIT_BLOCK+=("$block")
    EDIT_KEY+=("$key")
    EDIT_VALUE+=("$value")
  done < "$1"
}

# Whether block i has a line for key.
edit_block_has() {
  local i="$1" key="$2" j
  for ((j = 1; j <= ${#EDIT_BLOCK}; j++)); do
    ((EDIT_BLOCK[j] == i)) && [[ "${EDIT_KEY[j]}" == "$key" ]] && return 0
  done
  return 1
}

# A block's settings in the order written, "key value, key value", for the line that heads it.
edit_block_summary() {
  local i="$1" j
  local -a parts
  for ((j = 1; j <= ${#EDIT_BLOCK}; j++)); do
    ((EDIT_BLOCK[j] == i)) && parts+=("${EDIT_KEY[j]} ${EDIT_VALUE[j]}")
  done
  print -r -- "${(j:, :)parts}"
}

# settings.conf as the run read and checked it, kept to start every block from.
typeset -A EDIT_BASE

# The settings for block i, in the order a command line has them: settings.conf, the block's preset,
# its own lines, then the checks every run makes. Everything a block can set is set afresh, so
# nothing one block asked for reaches the next.
edit_block_settings() {
  local i="$1" j key value
  CFG=("${(@kv)EDIT_BASE}")
  IGNORED=()
  PRESET=""
  CUT_RANGES=()
  KEEP_RANGES=()
  RANGE_ORIGIN="in the block for ${EDIT_NAMES[i]}"
  for ((j = 1; j <= ${#EDIT_BLOCK}; j++)); do
    ((EDIT_BLOCK[j] == i)) && [[ "${EDIT_KEY[j]}" == preset ]] && PRESET="${EDIT_VALUE[j]}"
  done
  [[ -n "$PRESET" ]] && read_preset "$PRESET"
  for ((j = 1; j <= ${#EDIT_BLOCK}; j++)); do
    ((EDIT_BLOCK[j] == i)) || continue
    key="${EDIT_KEY[j]}"
    value="${EDIT_VALUE[j]}"
    case "$key" in
      cut) CUT_RANGES+=("$value") ;;
      keep) KEEP_RANGES+=("$value") ;;
      preset) ;;
      *) CFG[$key]="$value" ;;
    esac
  done
  validate_config
  # The run posts one banner and makes one copy at its end, from settings.conf.
  CFG[notify]=false
  CFG[copy_to_clipboard]=false
}

# A header names a recording beside the edit file by its name, any other by its path.
edit_source() {
  [[ "$1" == /* ]] && print -r -- "$1" || print -r -- "$2/$1"
}

# --------------------------------------------------------------------- running it

# What a run made, and the blocks it could not shrink, for its summary and its one banner.
typeset -a EDIT_MADE EDIT_FAILED

# edit_say <word> <text>: a step of the run on the screen under the word, and the text alone in the
# log.
edit_say() {
  local fd="$SCREEN_FD"
  screen_line "$1" "$2"
  SCREEN_FD=""
  log "$2"
  SCREEN_FD="$fd"
}

# A run that ends before its first recording: why, in red, and in the log.
edit_ends() {
  print -r -- "${PAINT[red]}${PAINT[bold]}$1${PAINT[reset]}"
  log "$1"
}

# Why block i of file cannot run at all, the way its line on the terminal says it, or nothing.
edit_block_refused() {
  local i="$1" file="$2" name="${EDIT_NAMES[$1]}" src
  src="$(edit_source "$name" "${file:h}")"
  if [[ ! -e "$src" ]]; then
    [[ "$name" == /* ]] && print -r -- "$name: not found" || print -r -- "$name: not found beside ${file:t}"
  elif [[ ! -f "$src" || "$src" != (#i)*.(mov|mp4|m4v) ]]; then
    print -r -- "$name is not a video (.mov, .mp4 or .m4v)"
  elif edit_block_has "$i" cut && edit_block_has "$i" keep; then
    # As main refuses --cut with --keep: letting one win would cut what the other keeps.
    print -r -- "$name: cut and keep are the same edit from opposite sides; this recording is left out"
  else
    return 1
  fi
}

# The lines that cannot be used, said before the first encode, then a blank line when anything was
# said, settings.conf's own lines among them.
edit_say_problems() {
  local problem
  for problem in "${EDIT_PROBLEMS[@]}"; do edit_say skipped "$problem"; done
  ((SCREEN_LINES)) && print
  return 0
}

# The lines that head block i: its number and name, then its settings as written.
edit_block_header() {
  local i="$1" summary
  summary="$(edit_block_summary $i)"
  print -r -- "${PAINT[bold]}[$i/${#EDIT_NAMES}]${PAINT[reset]} ${EDIT_NAMES[i]}"
  print -r -- "      ${PAINT[dim]}${summary:-settings.conf as it is}${PAINT[reset]}"
}

# What block i's settings come to, one line per key asked for, with nothing said on the terminal
# or in the log: each block says its own problems when it runs.
edit_block_quietly() {
  local i="$1" key
  shift
  (
    LOG=/dev/null
    SCREEN_FD=""
    edit_block_settings "$i" 2> /dev/null
    for key in "$@"; do print -r -- "${CFG[$key]}"; done
  )
}

# A recording's own frame rate as ffprobe states it, 60 or 30000/1001, or nothing.
frame_rate() {
  local rate
  rate="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$1" 2> /dev/null | head -1)"
  [[ "$rate" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] && print -r -- "${rate%/1}"
}

# The one format every block of a merged run is encoded to, in PART_FORMAT: the first block's
# codec; the largest width and height among the recordings, fitted to the first block's
# max_height; the first block's fps, or the first recording's own rate when that is 0; and sound
# when any block keeps some. A later block's codec, fps or max_height that differs from the first
# one's is not used, and each is said with the lines that cannot be used.
edit_merge_format() {
  local file="$1" n=${#EDIT_NAMES} i src width height maxw=0 maxh=0 sound=false rate prefix
  local -a mine codecs fpses heights
  for ((i = 1; i <= n; i++)); do
    src="$(edit_source "${EDIT_NAMES[i]}" "${file:h}")"
    mine=("${(@f)$(edit_block_quietly $i codec fps max_height remove_audio)}")
    codecs[i]="${mine[1]}"
    fpses[i]="${mine[2]}"
    heights[i]="${mine[3]}"
    width="$(video_width "$src")"
    height="$(video_height "$src")"
    ((width > maxw)) && maxw=$width
    ((height > maxh)) && maxh=$height
    [[ "${mine[4]}" == false ]] && has_audio "$src" && sound=true
  done
  if ((heights[1] > 0 && maxh > heights[1])); then
    maxw=$((maxw * heights[1] / maxh))
    maxh=${heights[1]}
  fi
  # libx264 refuses an odd frame size in yuv420p.
  ((maxw % 2)) && maxw=$((maxw + 1))
  ((maxh % 2)) && maxh=$((maxh + 1))
  rate="${fpses[1]}"
  ((rate > 0)) || rate="$(frame_rate "$(edit_source "${EDIT_NAMES[1]}" "${file:h}")")"
  rate="${rate:-${DEFAULTS[fps]}}"
  PART_FORMAT=(codec "${codecs[1]}" width "$maxw" height "$maxh" rate "$rate" sound "$sound")

  for ((i = 2; i <= n; i++)); do
    prefix="[$i/$n] ${EDIT_NAMES[i]}:"
    [[ "${codecs[i]}" == "${codecs[1]}" ]] || EDIT_PROBLEMS+=("$prefix codec ${codecs[i]} is not used; merge = true encodes every recording in the first one's ${codecs[1]}")
    [[ "${fpses[i]}" == "${fpses[1]}" ]] || EDIT_PROBLEMS+=("$prefix fps ${fpses[i]} is not used; merge = true encodes every recording at the first one's $rate fps")
    [[ "${heights[i]}" == "${heights[1]}" ]] || EDIT_PROBLEMS+=("$prefix max_height ${heights[i]} is not used; merge = true fits every recording into ${maxw}x${maxh}")
  done
  return 0
}

# merge = false, or a single block: each block shrunk beside its recording, under the name a
# one-shot run gives it.
edit_run_apart() {
  local file="$1" n=${#EDIT_NAMES} i src out refused
  edit_say_problems
  for ((i = 1; i <= n; i++)); do
    refused="$(edit_block_refused $i "$file")" && {
      edit_say skipped "[$i/$n] $refused"
      EDIT_FAILED+=("${EDIT_NAMES[i]}")
      continue
    }
    edit_block_header $i
    src="$(edit_source "${EDIT_NAMES[i]}" "${file:h}")"
    edit_block_settings $i
    out="$(free_name "${src:h}/$(output_name "$src")")"
    if shrink "$src" "$out" false; then
      EDIT_MADE+=("$out")
    else
      EDIT_FAILED+=("${EDIT_NAMES[i]}")
    fi
  done
  # One block has nothing to be joined to, so it is shrunk the way merge = false would.
  [[ "$EDIT_MERGE" == true ]] && ((${#EDIT_MADE})) \
    && edit_say note "merge = true needs two recordings; ${EDIT_NAMES[1]} was shrunk on its own"
  ((${#EDIT_FAILED} == 0))
}

# merge = true: every block encoded to the set's one format as a part, in a folder of its own in
# the temporary folder, then the parts joined by copying their streams into
# <edit file without .edit.txt>-merged.mp4 beside the edit file. A block that cannot be shrunk would
# leave a hole in the video, so the run joins nothing then: a block that cannot run at all is found
# before the first encode, and one whose encode fails stops the run there. The set's format is in
# PART_FORMAT already when every block can run (run_edit_file).
edit_run_merged() {
  local file="$1" n=${#EDIT_NAMES} i src out refused
  local -a parts refusals
  local nothing="[join] nothing joined: merge = true joins every recording or none"
  for ((i = 1; i <= n; i++)); do
    refused="$(edit_block_refused $i "$file")" || continue
    refusals+=("[$i/$n] $refused")
    EDIT_FAILED+=("${EDIT_NAMES[i]}")
  done
  edit_say_problems
  if ((${#refusals})); then
    for refused in "${refusals[@]}"; do edit_say skipped "$refused"; done
    edit_say failed "$nothing"
    return 1
  fi
  PARTS_DIR="$(mktemp -d "$(temp_folder)/shrinkit.$$.edit.XXXXXX")" || {
    edit_say failed "cannot make a folder for the parts in $(temp_folder)"
    return 1
  }
  for ((i = 1; i <= n; i++)); do
    edit_block_header $i
    src="$(edit_source "${EDIT_NAMES[i]}" "${file:h}")"
    edit_block_settings $i
    CFG[codec]="${PART_FORMAT[codec]}"
    out="$PARTS_DIR/$i/$(output_name "$src")"
    mkdir "${out:h}" && shrink "$src" "$out" false || {
      EDIT_FAILED+=("${EDIT_NAMES[i]}")
      remove_parts
      edit_say failed "$nothing"
      return 1
    }
    parts+=("$out")
  done
  print
  print -r -- "${PAINT[bold]}[join]${PAINT[reset]} $n parts"
  # Called directly, not in $(...): the traps find the part it writes in CURRENT_PART.
  merge_files "${file%.edit.txt}" "${parts[@]}" || {
    log "FAILED join of $n parts (the reason is above)"
    remove_parts
    return 1
  }
  remove_parts
  [[ "$MERGED_MODE" == re-encoded ]] \
    && log "joined by re-encoding: the parts did not agree, so it is larger than they are"
  EDIT_MADE+=("$MERGED_OUT")
}

# Whether every block of file can run at all.
edit_blocks_can_run() {
  local i
  for ((i = 1; i <= ${#EDIT_NAMES}; i++)); do
    edit_block_refused $i "$1" > /dev/null && return 1
  done
  return 0
}

# Every block in order, each through the one-shot path with its own settings, the log on the
# terminal as it goes; with merge = true and two blocks or more, joined into one video. Every line
# that cannot be used is said before the first encode, while there is still time for Ctrl-C. 0 when
# every recording was shrunk, and joined when asked to be. The note, if one is given, is said under
# the results when the run went through.
run_edit_file() {
  local file="${1:a}" note="${2-}" n merged=false rc about line
  mkdir -p "$LOG_DIR"
  [[ -x "$FFMPEG" ]] || {
    log "ffmpeg is not on PATH or in the Homebrew folders"
    print -u2 -r -- "ffmpeg is not on PATH or in the Homebrew folders"
    return 1
  }
  read_edit_file "$file"
  ((EDIT_RTF)) && {
    edit_ends "${file:t} was saved as rich text: in TextEdit, Format > Make Plain Text, save, and run it again"
    return 1
  }
  n=${#EDIT_NAMES}
  ((n > 0)) || {
    edit_ends "No recording in ${file:t}, nothing to run."
    return 1
  }
  ((n <= MAX_RECORDINGS)) || {
    print -u2 -r -- "run takes up to $MAX_RECORDINGS recordings at a time; ${file:t} has $n"
    log "run takes up to $MAX_RECORDINGS recordings at a time; ${file:t} has $n"
    return 2
  }
  [[ "$EDIT_MERGE" == true ]] && ((n > 1)) && merged=true
  log "run    $file"
  print -r -- "${PAINT[bold]}shrinkit run${PAINT[reset]}  ${file:t}"

  EDIT_MADE=() EDIT_FAILED=()
  exec {SCREEN_FD}>&1
  # settings.conf is read and checked once for the whole run, and what it has to say waits under
  # the line the set's format goes in, which needs it.
  SCREEN_HOLD=1
  read_config
  validate_config
  EDIT_BASE=("${(@kv)CFG}")
  about="$(recordings $n), merge = $EDIT_MERGE"
  if [[ "$merged" == true ]] && edit_blocks_can_run "$file"; then
    edit_merge_format "$file"
    about="$about, every part ${PART_FORMAT[width]}x${PART_FORMAT[height]} at ${PART_FORMAT[rate]} fps"
  fi
  SCREEN_HOLD=0
  print -r -- "${PAINT[dim]}$about${PAINT[reset]}"
  print
  for line in "${SCREEN_HELD[@]}"; do print -r -- "$line"; done
  SCREEN_HELD=()

  if [[ "$merged" == true ]]; then
    edit_run_merged "$file"
  else
    edit_run_apart "$file"
  fi
  rc=$?
  PART_FORMAT=()
  exec {SCREEN_FD}>&-
  SCREEN_FD=""

  edit_summary "$rc" "$merged" "$n" "$note"
  return $rc
}

# How long a result plays, as 13.0s, or nothing when it does not say.
edit_length() {
  local dur
  dur="$(clip_duration "$1")"
  [[ -n "$dur" ]] && printf '%.1fs' "$dur"
}

# A result's path with its folder dimmed, so the name stands out.
edit_path() {
  print -r -- "${PAINT[dim]}${1:h}/${PAINT[reset]}${1:t}"
}

# The end of a run: what came out, with its size and how long it plays, what did not, and what else
# happened; then its one banner and its one copy.
edit_summary() {
  local rc="$1" merged="$2" n="$3" note="$4" out
  local -a notes
  print
  if ((rc == 0 && ${#EDIT_MADE} == 1)); then
    out="${EDIT_MADE[1]}"
    print -r -- "${PAINT[green]}${PAINT[bold]}Done${PAINT[reset]}  ${PAINT[bold]}$(human_size "$out")${PAINT[reset]}  ${PAINT[dim]}$(edit_length "$out")${PAINT[reset]}"
    print -r -- "      $(edit_path "$out")"
  else
    if ((rc == 0)); then
      print -r -- "${PAINT[green]}${PAINT[bold]}Done${PAINT[reset]}"
    elif [[ "$merged" == true ]]; then
      print -r -- "${PAINT[red]}${PAINT[bold]}Nothing was joined.${PAINT[reset]}"
    else
      print -r -- "${PAINT[red]}${PAINT[bold]}Not every recording was shrunk.${PAINT[reset]}"
    fi
    for out in "${EDIT_MADE[@]}"; do
      print -r -- "      $(edit_path "$out")  ${PAINT[bold]}$(human_size "$out")${PAINT[reset]}  ${PAINT[dim]}$(edit_length "$out")${PAINT[reset]}"
    done
  fi
  ((${#EDIT_FAILED})) && print -r -- "      Not shrunk: ${(j:, :)EDIT_FAILED}"
  edit_announce "$n" "${(j:, :)EDIT_FAILED}" "${EDIT_MADE[@]}" && notes+=("copied to the clipboard")
  ((rc == 0)) && [[ -n "$note" ]] && notes+=("$note")
  ((${#notes})) && print -r -- "      ${PAINT[dim]}${(j:; :)notes}${PAINT[reset]}"
  return 0
}

# The one banner and the one copy of a run, both as settings.conf has them: what came out, and
# what did not. 0 when the results went on the clipboard.
edit_announce() {
  local n="$1" failed="$2" extra="" copied=1
  shift 2
  CFG=("${(@kv)EDIT_BASE}")
  if [[ "${CFG[copy_to_clipboard]}" == true ]] && (($#)); then
    copy_to_clipboard "$@"
    extra=", copied to clipboard"
    copied=0
  fi
  if (($# == 0)); then
    # Nothing came out while no block failed only when a merged run's join did.
    if [[ -n "$failed" ]]; then
      notify "Not shrunk: $failed" "Could not shrink"
    else
      notify "$(recordings $n) shrunk, but nothing was joined" "Could not merge"
    fi
  elif [[ -z "$failed" ]]; then
    notify "$(recordings $n) shrunk: ${(j:, :)@:t}$extra" "shrinkit edit"
  else
    notify "$# of $n shrunk: ${(j:, :)@:t}$extra. Not shrunk: $failed" "shrinkit edit"
  fi
  return $copied
}

# shrinkit run <file>: an edit file written before, run again. The right-click entry runs it as run
# --finder <file>..., and the Terminal window it opens takes the file with run --next; neither is in
# the usage text.
run_command() {
  local window=false file
  case "${1-}" in
    --finder)
      shift
      run_finder "$@"
      return
      ;;
    --next)
      window=true
      # Terminal's Last login line and the launcher's path go with the screen and what scrolled off it.
      print -rn -- $'\e[H\e[2J\e[3J'
      file="$(take_edit_request)" || {
        print -r -- "No edit file is waiting. Select one in Finder and pick shrinkit: run."
        return 1
      }
      set -- "$file"
      ;;
  esac
  (($# == 1)) || {
    print -u2 -r -- "run needs one edit file: shrinkit run <file>"
    return 2
  }
  [[ -f "$1" && -r "$1" ]] || {
    print -u2 -r -- "cannot read $1"
    return 2
  }
  if [[ "$window" == true ]]; then
    edit_window "$1"
  else
    run_edit_file "$1"
  fi
}

# --------------------------------------------------------------------- the Terminal window

# The window: the file run at once, what came out shown in Finder, and the window closed when the
# run went through; when it stays open, how to run the file again. It closes only when it knows its
# terminal, the one this reads from.
edit_window() {
  local file="${1:a}" rc tty
  tty="$(tty)" || tty=""
  run_edit_file "$file" "${tty:+this window closes in 3 seconds}"
  rc=$?
  if ((rc != 0)) || [[ -z "$tty" ]]; then
    print
    print -r -- "To run it again: shrinkit run ${(qq)file}"
  fi
  ((${#EDIT_MADE})) && open -R "${EDIT_MADE[@]}"
  ((rc == 0)) && [[ -n "$tty" ]] && close_window_later "$tty"
  return $rc
}

# --------------------------------------------------------------------- shrinkit edit

# The videos among the names given, as absolute paths in merge order, one per line. What is not a
# video is said on stderr and in the log, the way a one-shot run says it.
edit_videos() {
  local src i
  local -a videos
  for src in "$@"; do
    [[ -f "$src" ]] || {
      log "skip   $src (not a file)"
      print -u2 -r -- "'$src' is not a file"
      continue
    }
    [[ "$src" == (#i)*.(mov|mp4|m4v) ]] || {
      log "skip   ${src:t} (not a video)"
      print -u2 -r -- "${src:t} is not a video (.mov, .mp4 or .m4v)"
      continue
    }
    videos+=("${src:a}")
  done
  ((${#videos})) || return 0
  for i in ${(f)"$(merge_order "${videos[@]}")"}; do print -r -- "${videos[i]}"; done
}

# shrinkit edit <file>...: the recordings' edit file, written unless an edit of the same set left
# it there, opened in the editor the way git opens one, and run once the editor closes without an
# error. edit --finder is the right-click entry's, not in the usage text.
edit_command() {
  local file rc
  local -a videos editor
  [[ "${1-}" == --finder ]] && {
    shift
    edit_finder "$@"
    return
  }
  mkdir -p "$LOG_DIR"
  videos=(${(f)"$(edit_videos "$@")"})
  ((${#videos})) || {
    print -u2 -r -- "edit needs at least one video (.mov, .mp4 or .m4v)"
    return 2
  }
  ((${#videos} <= MAX_RECORDINGS)) || {
    print -u2 -r -- "edit takes up to $MAX_RECORDINGS recordings at a time; ${#videos} were given"
    log "edit takes up to $MAX_RECORDINGS recordings at a time; ${#videos} were given"
    return 2
  }
  file="$(edit_file_for "${videos[@]}")"
  if [[ ! -e "$file" ]]; then
    write_edit_file "$file" \
      "Edit this file, save it and close the editor to run it. Delete every block to cancel." \
      "${videos[@]}" || {
      print -u2 -r -- "cannot write $file"
      return 1
    }
  fi

  editor=(${=${VISUAL:-${EDITOR:-vi}}})
  "${editor[@]}" "$file"
  rc=$?
  ((rc == 0)) || {
    print -u2 -r -- "${editor[1]:t} exited with $rc, so nothing was run. The file stays: $file"
    return 1
  }
  run_edit_file "$file"
}

# --------------------------------------------------------------------- shrinkit: edit

# The right-click entry for several recordings at once.
install_edit_action() {
  install_quick_action edit \
    "SHRINKIT_DIR=${(qq)BASE_DIR} ${(qq)$(registered_path)} edit --finder \"\$@\""
}

# What the entry runs: the recordings' edit file, written unless an edit of the same set left it
# there, opened in TextEdit, and nothing else; shrinkit: run runs it once it is saved. A problem is
# said in a banner as well, since nothing a Quick Action prints is ever seen.
edit_finder() {
  local file
  local -a videos
  mkdir -p "$LOG_DIR"
  read_config
  validate_config
  videos=(${(f)"$(edit_videos "$@")"})
  ((${#videos})) || {
    finder_says "shrinkit: edit needs a video"
    return 2
  }
  ((${#videos} <= MAX_RECORDINGS)) || {
    finder_says "shrinkit: edit takes up to $MAX_RECORDINGS recordings at a time; ${#videos} were selected"
    return 2
  }
  file="$(edit_file_for "${videos[@]}")"
  if [[ ! -e "$file" ]]; then
    write_edit_file "$file" \
      "Edit this file, save it, then right-click it in Finder and pick shrinkit: run." \
      "${videos[@]}" || {
      finder_says "shrinkit: edit cannot write in ${file:h}"
      return 1
    }
  fi
  open -e "$file"
}

finder_says() {
  print -u2 -r -- "$1"
  log "$1"
  notify "$1"
}

# --------------------------------------------------------------------- shrinkit: run

# The right-click entry for edit files, which Finder takes for plain text.
install_run_action() {
  install_quick_action run \
    "SHRINKIT_DIR=${(qq)BASE_DIR} ${(qq)$(registered_path)} run --finder \"\$@\"" public.plain-text
}

# What the entry runs: for each edit file among the files it is handed, a request in the queue and
# a Terminal window to take it.
run_finder() {
  local src
  local -a files
  mkdir -p "$LOG_DIR"
  read_config
  validate_config
  for src in "$@"; do
    if [[ -f "$src" && "$src" == (#i)*.edit.txt ]]; then
      files+=("${src:a}")
    else
      log "skip   ${src:t} (not an edit file)"
    fi
  done
  ((${#files})) || {
    finder_says "shrinkit: run takes an edit file (shrinkit-<code>.edit.txt)"
    return 2
  }
  for src in "${files[@]}"; do
    start_edit_window "$src" || {
      finder_says "shrinkit: run could not open a Terminal window. To run the file: shrinkit run ${(qq)src}"
      return 1
    }
  done
}
