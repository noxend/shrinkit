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

# settings.conf as the run read it, kept to start every block from.
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
}

# A header names a recording beside the edit file by its name, any other by its path.
edit_source() {
  [[ "$1" == /* ]] && print -r -- "$1" || print -r -- "$2/$1"
}

# --------------------------------------------------------------------- running it

# One line on the terminal as it is, and the same words in the log.
edit_say() {
  local fd="$SCREEN_FD"
  print -r -- "$1"
  SCREEN_FD=""
  log "$1"
  SCREEN_FD="$fd"
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

# Every block in order, each through the one-shot path with its own settings, the log on the
# terminal as it goes. Every line that cannot be used is said before the first encode, while there
# is still time for Ctrl-C. 0 when every recording was shrunk.
run_edit_file() {
  local file="${1:a}" i n src out summary refused problem
  local -a made failed
  mkdir -p "$LOG_DIR"
  read_config
  EDIT_BASE=("${(@kv)CFG}")
  [[ -x "$FFMPEG" ]] || {
    log "ffmpeg is not on PATH or in the Homebrew folders"
    print -u2 -r -- "ffmpeg is not on PATH or in the Homebrew folders"
    return 1
  }
  read_edit_file "$file"
  ((EDIT_RTF)) && {
    edit_say "${file:t} was saved as rich text: in TextEdit, Format > Make Plain Text, save, and run it again"
    return 1
  }
  n=${#EDIT_NAMES}
  ((n > 0)) || {
    edit_say "No recording in ${file:t}, nothing to run."
    return 1
  }
  log "run    $file"
  print -r -- "Running ${file:t}: $(recordings $n), merge = $EDIT_MERGE"
  print

  exec {SCREEN_FD}>&1
  for problem in "${EDIT_PROBLEMS[@]}"; do log "$problem"; done
  ((${#EDIT_PROBLEMS})) && print
  for ((i = 1; i <= n; i++)); do
    refused="$(edit_block_refused $i "$file")" && {
      edit_say "[$i/$n] $refused"
      failed+=("${EDIT_NAMES[i]}")
      continue
    }
    summary="$(edit_block_summary $i)"
    print -r -- "[$i/$n] ${EDIT_NAMES[i]}${summary:+   $summary}"
    src="$(edit_source "${EDIT_NAMES[i]}" "${file:h}")"
    edit_block_settings $i
    out="$(free_name "${src:h}/$(output_name "$src")")"
    if shrink "$src" "$out" false; then
      made+=("$out")
    else
      failed+=("${EDIT_NAMES[i]}")
    fi
  done
  exec {SCREEN_FD}>&-
  SCREEN_FD=""

  print
  ((${#failed})) && print -r -- "Not every recording was shrunk." || print -r -- "Done."
  for out in "${made[@]}"; do print -r -- "  $out  ($(human_size "$out"))"; done
  ((${#failed} == 0)) || {
    print -r -- "Not shrunk: ${(j:, :)failed}"
    return 1
  }
}

# shrinkit run <file>: an edit file written before, run again.
run_command() {
  (($# == 1)) || {
    print -u2 -r -- "run needs one edit file: shrinkit run <file>"
    return 2
  }
  [[ -f "$1" && -r "$1" ]] || {
    print -u2 -r -- "cannot read $1"
    return 2
  }
  run_edit_file "$1"
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

# shrinkit edit <file>...: the edit file beside the first recording, opened in the editor the way
# git opens one, and run once the editor closes without an error.
edit_command() {
  local file rc
  local -a videos editor
  mkdir -p "$LOG_DIR"
  videos=(${(f)"$(edit_videos "$@")"})
  ((${#videos})) || {
    print -u2 -r -- "edit needs at least one video (.mov, .mp4 or .m4v)"
    return 2
  }
  file="$(free_name "${videos[1]:r}.edit.txt" edit.txt)"
  write_edit_file "$file" \
    "Edit this file, save it and close the editor to run it. Delete every block to cancel." \
    "${videos[@]}" || {
    print -u2 -r -- "cannot write $file"
    return 1
  }

  editor=(${=${VISUAL:-${EDITOR:-vi}}})
  "${editor[@]}" "$file"
  rc=$?
  ((rc == 0)) || {
    print -u2 -r -- "${editor[1]:t} exited with $rc, so nothing was run. The file stays: $file"
    return 1
  }
  run_edit_file "$file"
}
