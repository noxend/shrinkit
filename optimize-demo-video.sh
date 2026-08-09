#!/bin/zsh
#
# Optimizes screen recordings dropped into the input folder: speeds them up, drops or stretches the
# audio, and re-encodes them small. Settings live in settings.conf next to the folders, so this
# script never needs editing. A launchd WatchPaths agent runs it whenever something lands in
# input/, and running it by hand does exactly the same thing.

set -u
setopt extended_glob

# --------------------------------------------------------------------- where things live

BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"
REPO_DIR="${DEMO_OPTIMIZER_REPO:-}" # set by the installer, used for the update check

IN_DIR="$BASE_DIR/input"        # the watched folder
DONE_DIR="$BASE_DIR/.processed" # originals end up here after a good encode
LOG_DIR="$BASE_DIR/.logs"
LOG="$LOG_DIR/optimizer.log"
LOCK_DIR="$BASE_DIR/.optimizer.lock"
UPDATE_STAMP="$LOG_DIR/.last-update-check"

CONFIG="$BASE_DIR/settings.conf"
# named variations on the config, one file each
PRESET_DIR="$BASE_DIR/presets"
# converted by the installer
LEGACY_CONFIGS=("$BASE_DIR/settings.jsonc" "$BASE_DIR/settings.txt")

OUT_DIR="$BASE_DIR/output" # settings.output_dir can point this somewhere else

# First hit wins: whatever is on PATH, then the two usual Homebrew prefixes.
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

log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"
}

# --------------------------------------------------------------------- settings

# These double as the whitelist: a key the config names that is not in here gets ignored, which is
# what keeps a typo harmless.
typeset -A DEFAULTS=(
  speed 2    # 2 = twice as fast
  fps 30     # frame-rate cap, 0 keeps the original
  crf 28     # the size knob, 0-51, higher is smaller
  codec h264 # h264 or hevc
  remove_audio true
  trim_idle false           # drop stretches where the screen is not changing
  max_height 0              # downscale tall videos, 0 keeps the original size
  output_suffix '-{speed}x' # {speed} is filled in, so the name follows a speed change
  keep_original true        # move the source aside instead of deleting it
  notify true
  notify_start true # also show a quiet banner when a file starts, not just when it finishes
  notify_title "Video optimized"
  notify_sound Glass # any /System/Library/Sounds name, or none
  copy_to_clipboard false
  check_updates true
  output_dir "" # empty means <base>/output
)
typeset -A CFG
CFG=("${(@kv)DEFAULTS}")

trim() {
  print -r -- "${${1##[[:space:]]#}%%[[:space:]]#}"
}

# "key = value" lines. A whole line starting with # is a comment; a # anywhere else is part of the
# value, so a banner title can contain one. A key we do not know about is ignored, which is what
# keeps a typo harmless, and a line that makes no sense spoils only itself.
read_settings() {
  local line key value
  while IFS= read -r line; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == '#'* || "$line" != *=* ]] && continue
    key="${(L)${line%%=*}//[[:space:]]/}"
    value="$(trim "${line#*=}")"
    [[ -n "${DEFAULTS[$key]+known}" ]] && CFG[$key]="${value//\"/}"
  done < "$1"
}

read_config() {
  local stale
  if [[ ! -f "$CONFIG" ]]; then
    for stale in "${LEGACY_CONFIGS[@]}"; do
      [[ -f "$stale" ]] && log "found ${stale:t}; run install.sh to convert it to ${CONFIG:t}"
    done
    return 0
  fi
  read_settings "$CONFIG"
}

# A preset is the same file in presets/, read on top of the config. It is how one recording gets
# handled differently without the settings for every other one moving.
preset_file() {
  print -r -- "$PRESET_DIR/$1.conf"
}

read_preset() {
  local file
  file="$(preset_file "$1")"
  [[ -f "$file" ]] || {
    log "no preset called '$1' in $PRESET_DIR"
    print -u2 -r -- "no preset called '$1' (looked in $PRESET_DIR)"
    return 1
  }
  read_settings "$file"
}

# Written as regexes rather than zsh's <-> globs so shell tooling can still parse this file.
is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}
is_num() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}
is_bool() {
  [[ "$1" == true || "$1" == false ]]
}

# Put one setting back to its default and say so, so a bad value never stops a run.
reject() {
  local key="$1" reason="$2"
  log "ignoring $key='${CFG[$key]}' ($reason), using '${DEFAULTS[$key]}'"
  CFG[$key]="${DEFAULTS[$key]}"
}

validate_config() {
  is_num "${CFG[speed]}" && awk -v s="${CFG[speed]}" 'BEGIN { exit !(s > 0) }' \
    || reject speed "want a number above 0"
  is_int "${CFG[fps]}" || reject fps "want a whole number"
  is_int "${CFG[crf]}" && ((CFG[crf] <= 51)) || reject crf "want 0-51"
  is_int "${CFG[max_height]}" || reject max_height "want a whole number"
  [[ "${CFG[codec]}" == h264 || "${CFG[codec]}" == hevc ]] || reject codec "want h264 or hevc"
  is_bool "${CFG[remove_audio]}" || reject remove_audio "want true or false"
  is_bool "${CFG[trim_idle]}" || reject trim_idle "want true or false"
  is_bool "${CFG[keep_original]}" || reject keep_original "want true or false"
  is_bool "${CFG[notify]}" || reject notify "want true or false"
  is_bool "${CFG[notify_start]}" || reject notify_start "want true or false"
  is_bool "${CFG[copy_to_clipboard]}" || reject copy_to_clipboard "want true or false"
  is_bool "${CFG[check_updates]}" || reject check_updates "want true or false"
  [[ -n "${CFG[output_suffix]}" ]] || reject output_suffix "cannot be empty"
  [[ -n "${CFG[notify_title]}" ]] || reject notify_title "cannot be empty"
}

resolve_output_suffix() {
  CFG[output_suffix]="${CFG[output_suffix]//\{speed\}/${CFG[speed]}}"
}

# output_dir may point anywhere, as long as it is an absolute path we can actually create.
resolve_output_dir() {
  local wanted="${CFG[output_dir]}"
  if [[ -n "$wanted" ]]; then
    if [[ "$wanted" == /* || "$wanted" == "~/"* ]]; then
      OUT_DIR="${wanted/#\~/$HOME}"
    else
      log "ignoring output_dir='$wanted' (want an absolute path)"
    fi
  fi
  mkdir -p "$OUT_DIR" 2> /dev/null || {
    log "cannot create '$OUT_DIR', falling back to the default output folder"
    OUT_DIR="$BASE_DIR/output"
    mkdir -p "$OUT_DIR"
  }
}

# --------------------------------------------------------------------- macOS niceties

# Banner text and sound are configurable; the icon is not, macOS pins it to Script Editor's.
notify() {
  [[ "${CFG[notify]}" == true ]] || return 0
  local message="$1" title="${2:-${CFG[notify_title]}}" sound="${3-${CFG[notify_sound]}}"
  [[ "$sound" == none || "$sound" == off || "$sound" == silent || "$sound" == no ]] && sound=""
  osascript -l JavaScript - "$title" "$message" "$sound" << 'JXA' > /dev/null 2>&1 || true
function run(argv) {
  const [title, message, sound] = argv;
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  const options = { withTitle: title };
  if (sound) options.soundName = sound;
  app.displayNotification(message, options);
}
JXA
}

# A quiet "started" banner, so a drop does not sit there with no sign it was noticed.
notify_start() {
  [[ "${CFG[notify_start]}" == true ]] || return 0
  notify "$1" "Optimizing…" none
}

# Writes to NSPasteboard directly, so this needs no permission to control other apps.
copy_to_clipboard() {
  osascript -l JavaScript - "$1" << 'JXA' > /dev/null 2>&1 || true
function run(argv) {
  ObjC.import('AppKit');
  const board = $.NSPasteboard.generalPasteboard;
  board.clearContents;
  board.writeObjects($.NSArray.arrayWithObject($.NSURL.fileURLWithPath(argv[0])));
}
JXA
}

# --------------------------------------------------------------------- encoding

# A recorder writes its file gradually, so wait until the size stops moving before touching it.
is_settled() {
  local file="$1" first second
  first="$(stat -f%z "$file" 2> /dev/null)" || return 1
  sleep 2
  second="$(stat -f%z "$file" 2> /dev/null)" || return 1
  [[ "$first" == "$second" && "$first" -gt 0 ]]
}

video_height() {
  local height
  height="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height \
    -of default=nw=1:nk=1 "$1" 2> /dev/null | head -1)"
  is_int "$height" && print -r -- "$height" || print -r -- 1080
}

has_audio() {
  [[ -n "$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
    -of csv=p=0 "$1" 2> /dev/null | head -1)" ]]
}

human_size() {
  du -h "$1" | cut -f1 | tr -d ' '
}

# Trimming has to run first, on the original frames: mpdecimate throws the near-identical ones
# away and the setpts after it pulls what is left back onto a continuous timeline. Then the
# downscale, the speed change and the frame-rate cap.
video_filters() {
  local height="$1" trim="$2" chain=""
  [[ "$trim" == true ]] && chain="mpdecimate,setpts=N/FRAME_RATE/TB,"
  ((CFG[max_height] > 0 && height > CFG[max_height])) && chain="${chain}scale=-2:${CFG[max_height]},"
  chain="${chain}setpts=PTS/${CFG[speed]}"
  ((CFG[fps] > 0)) && chain="$chain,fps=${CFG[fps]}"
  print -r -- "$chain"
}

# atempo only stretches by 0.5x to 2x at a time, so chain stages for anything past that.
atempo_chain() {
  awk -v s="$1" 'BEGIN {
    while (s > 2.0) { printf "atempo=2.0,"; s /= 2.0 }
    while (s < 0.5) { printf "atempo=0.5,"; s /= 0.5 }
    printf "atempo=%.4f", s
  }'
}

# Encodes one file to a given path. Non-zero means ffmpeg failed and nothing usable was written.
# Quality-based (CRF) rather than a fixed bitrate, which matters a lot for screen recordings: a
# fixed bitrate can make them bigger than the original.
encode() {
  local src="$1" out="$2" height
  height="$(video_height "$src")"

  # Dropping video frames leaves the audio at its old length, so trimming and a kept audio track
  # cannot both happen. The audio is what the file was asked to keep, so trimming stands down.
  local -a audio codec
  local trim=false
  if [[ "${CFG[remove_audio]}" == true ]] || ! has_audio "$src"; then
    audio=(-an)
    trim="${CFG[trim_idle]}"
  else
    audio=(-c:a aac -b:a 128k -filter:a "$(atempo_chain "${CFG[speed]}")")
    [[ "${CFG[trim_idle]}" == true ]] && log "not trimming ${src:t} (it would pull the kept audio out of sync)"
  fi

  if [[ "${CFG[codec]}" == hevc ]]; then
    codec=(-c:v libx265 -tag:v hvc1)
  else
    codec=(-c:v libx264)
  fi
  codec+=(-crf "${CFG[crf]}" -preset veryfast)

  local label="${height}p, ${CFG[speed]}x, ${CFG[fps]}fps, ${CFG[codec]} crf${CFG[crf]}"
  [[ "$trim" == true ]] && label="$label, trimmed"

  log "encode ${src:t} ($label)"
  "$FFMPEG" -nostdin -y -i "$src" -filter:v "$(video_filters "$height" "$trim")" \
    "${audio[@]}" "${codec[@]}" -pix_fmt yuv420p -movflags +faststart \
    "$out" >> "$LOG" 2>&1 || {
    rm -f "$out"
    return 1
  }
}

# The size line, clipboard copy and finished banner, shared by both modes.
announce() {
  local name="$1" out="$2" before="$3" after="$4" extra=""
  if [[ "${CFG[copy_to_clipboard]}" == true ]]; then
    copy_to_clipboard "$out"
    extra=", copied to clipboard"
  fi
  log "done   ${out:t} ($before -> $after)$extra"
  notify "$name   $before -> $after$extra"
}

# Folder mode: encode into the output folder and file the original away.
handle() {
  local src="$1" out="$2" before after
  before="$(human_size "$src")"
  notify_start "${src:t:r}"

  encode "$src" "$out" || {
    log "FAILED ${src:t}, left in place (ffmpeg output is above)"
    notify "${src:t}" "Optimize failed"
    return 1
  }
  after="$(human_size "$out")"

  if [[ "${CFG[keep_original]}" == true ]]; then
    mv "$src" "$DONE_DIR/"
  else
    rm -f "$src"
  fi
  announce "${src:t:r}" "$out" "$before" "$after"
}

# One-shot mode (the Finder Quick Action): optimize the given files in place, writing the result
# next to each source and leaving the originals alone.
optimize_files() {
  local src out before after
  for src in "$@"; do
    [[ -f "$src" ]] || {
      log "skip   $src (not a file)"
      continue
    }
    out="${src:h}/${src:t:r}${CFG[output_suffix]}.mp4"
    [[ -e "$out" ]] && out="${src:h}/${src:t:r}${CFG[output_suffix]}-$(date +%s).mp4"

    before="$(human_size "$src")"
    notify_start "${src:t:r}"
    if encode "$src" "$out"; then
      after="$(human_size "$out")"
      announce "${src:t:r}" "$out" "$before" "$after"
    else
      log "FAILED $src (one-shot, ffmpeg output is above)"
      notify "${src:t}" "Optimize failed"
    fi
  done
}

# Keeps going until the folder is empty. Re-reading it after every file is what catches a
# recording dropped mid-encode: launchd swallows those events while we are already running. A pass
# that gets nowhere ends the loop, so a half-written or broken file cannot spin forever.
process_queue() {
  local -a pending
  local src out progressed=1 seen=0

  while ((progressed)); do
    progressed=0
    pending=("$IN_DIR"/(#i)*.(mov|mp4|m4v)(N.))
    for src in "${pending[@]}"; do
      seen=1
      out="$OUT_DIR/${src:t:r}${CFG[output_suffix]}.mp4"
      if [[ -e "$out" ]]; then
        log "skip   ${src:t} (already has an optimized copy)"
      elif ! is_settled "$src"; then
        log "skip   ${src:t} (still being written)"
      elif handle "$src" "$out"; then
        progressed=1
      fi
    done
  done

  ((seen)) || log "nothing new to do"
}

# --------------------------------------------------------------------- update check

# Once a day, mention that the clone is behind. The stamp is written before fetching so a hang
# cannot turn into a retry loop, and ssh gets a timeout so a dead network cannot hold up the queue.
check_for_updates() {
  [[ "${CFG[check_updates]}" == true && -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]] || return 0

  local last behind
  last="$(cat "$UPDATE_STAMP" 2> /dev/null)"
  is_int "$last" || last=0
  (($(date +%s) - last >= 86400)) || return 0
  date +%s > "$UPDATE_STAMP"

  git -C "$REPO_DIR" -c core.sshCommand='ssh -o ConnectTimeout=8 -o BatchMode=yes' \
    fetch --quiet origin main 2> /dev/null || return 0

  behind="$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2> /dev/null)"
  is_int "$behind" && ((behind > 0)) || return 0

  log "update available: $behind new commit(s) on origin/main"
  notify "$behind new commit(s), run update.sh" "Update available"
}

# --------------------------------------------------------------------- run

# mkdir is atomic, so it doubles as the lock, and the pid inside says who holds it. Liveness is
# what decides whether a lock may be taken over: a signal test cannot mistake a long encode for an
# abandoned run the way a timeout can, and it frees a killed run's lock at once instead of after a
# wait. The release has to be armed at the top level: in zsh an EXIT trap set inside a function
# fires when that function returns, which would drop the lock immediately.
LOCK_HELD=0
LOCK_PID_FILE="$LOCK_DIR/pid"

lock_owner_alive() {
  local owner
  owner="$(cat "$LOCK_PID_FILE" 2> /dev/null)"
  is_int "$owner" && kill -0 "$owner" 2> /dev/null
}

acquire_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    lock_owner_alive && return 1
    rm -f "$LOCK_PID_FILE" 2> /dev/null
    rmdir "$LOCK_DIR" 2> /dev/null
  fi
  mkdir "$LOCK_DIR" 2> /dev/null || return 1
  print -r -- $$ > "$LOCK_PID_FILE"
  LOCK_HELD=1
}

# Only drop a lock we still own, so a run that was taken over cannot delete its successor's.
release_lock() {
  ((LOCK_HELD)) || return 0
  [[ "$(cat "$LOCK_PID_FILE" 2> /dev/null)" == "$$" ]] || return 0
  rm -f "$LOCK_PID_FILE" 2> /dev/null
  rmdir "$LOCK_DIR" 2> /dev/null
}

# --------------------------------------------------------------------- presets

SERVICES_DIR="$HOME/Library/Services"

# The bundle Automator wants is fiddly enough that it is copied rather than written from scratch.
# The installed Quick Action is a copy of the same thing, so it works as the template when the
# repo is not around.
quick_action_template() {
  local candidate
  for candidate in "$REPO_DIR/quick-action/Optimize Video.workflow" \
    "$SERVICES_DIR/Optimize Video.workflow"; do
    [[ -d "$candidate" ]] && {
      print -r -- "$candidate"
      return
    }
  done
  return 1
}

preset_names() {
  local file
  for file in "$PRESET_DIR"/*.conf(N.); do print -r -- "${file:t:r}"; done
}

install_preset_action() {
  local name="$1" template action command
  [[ -f "$(preset_file "$name")" ]] || {
    print -u2 -r -- "no preset called '$name' (looked in $PRESET_DIR)"
    return 1
  }
  template="$(quick_action_template)" || {
    print -u2 -r -- "cannot find a Quick Action to copy; run install.sh first"
    return 1
  }

  action="$SERVICES_DIR/Optimize $name.workflow"
  mkdir -p "$SERVICES_DIR"
  rm -rf "$action"
  cp -R "$template" "$action"

  command="DEMO_OPTIMIZER_DIR=\"$BASE_DIR\" \"${ZSH_ARGZERO:A}\" --preset \"$name\" \"\$@\""
  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string "$command" \
    "$action/Contents/document.wflow"
  plutil -replace CFBundleName -string "Optimize $name" "$action/Contents/Info.plist"
  plutil -replace NSServices.0.NSMenuItem.default -string "Optimize $name" \
    "$action/Contents/Info.plist"
  /System/Library/CoreServices/pbs -update 2> /dev/null || true

  print -r -- "right-click a video > Quick Actions > Optimize $name"
}

remove_preset_action() {
  rm -rf "$SERVICES_DIR/Optimize $1.workflow"
  /System/Library/CoreServices/pbs -update 2> /dev/null || true
  print -r -- "removed the Quick Action for '$1'"
}

preset_command() {
  mkdir -p "$PRESET_DIR"
  case "${1-}" in
    list | "")
      preset_names
      ;;
    install)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: preset install <name>"
        return 2
      }
      install_preset_action "$2" || return 2
      ;;
    remove)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: preset remove <name>"
        return 2
      }
      remove_preset_action "$2"
      ;;
    *)
      print -u2 -r -- "usage: preset [list|install <name>|remove <name>]"
      return 2
      ;;
  esac
}

# --------------------------------------------------------------------- run

usage() {
  print -r -- "usage: ${ZSH_ARGZERO:t} [--setting value ...] [file ...]
       ${ZSH_ARGZERO:t} preset [list|install <name>|remove <name>]

  no files       optimize everything waiting in $IN_DIR
  file ...       optimize those files where they are, next to each source

Every setting is also a flag, so --crf 24 or --speed 3 changes one run without
touching the config. A true/false setting takes no value: --trim-idle turns it
on, --no-trim-idle turns it off.

A preset is a file of the same settings in $PRESET_DIR.
Use one for a run with --preset <name>, or turn it into its own right-click
entry with 'preset install <name>'.

  settings       $CONFIG
  presets        $PRESET_DIR
  log            $LOG"
}

# Any setting can be given as a flag, which is why there is no list of them here: --crf 24 for the
# ones that take a value, --trim-idle and --no-trim-idle for the true/false ones. Anything that is
# not a flag is a file to work on.
typeset -A OVERRIDES
typeset -a FILES
PRESET=""

# 1 means there is nothing left to do (--help), 2 means the command line was wrong.
parse_args() {
  local arg key
  while (($# > 0)); do
    arg="$1"
    case "$arg" in
      -h | --help)
        usage
        return 1
        ;;
      --preset)
        shift
        (($# > 0)) || {
          print -u2 -r -- "--preset needs a name"
          return 2
        }
        PRESET="$1"
        ;;
      --no-*)
        key="${${arg#--no-}//-/_}"
        known_bool "$key" "$arg" || return 2
        OVERRIDES[$key]=false
        ;;
      --*)
        key="${${arg#--}//-/_}"
        known_setting "$key" "$arg" || return 2
        if is_bool "${DEFAULTS[$key]}"; then
          OVERRIDES[$key]=true
        else
          shift
          (($# > 0)) || {
            print -u2 -r -- "$arg needs a value"
            return 2
          }
          OVERRIDES[$key]="$1"
        fi
        ;;
      -*)
        print -u2 -r -- "unknown option: $arg"
        usage >&2
        return 2
        ;;
      *) FILES+=("$arg") ;;
    esac
    shift
  done
}

known_setting() {
  [[ -n "${DEFAULTS[$1]+known}" ]] && return 0
  print -u2 -r -- "unknown option: $2"
  usage >&2
  return 1
}

known_bool() {
  known_setting "$1" "$2" || return 1
  is_bool "${DEFAULTS[$1]}" && return 0
  print -u2 -r -- "$2 only works on a true/false setting"
  return 1
}

apply_overrides() {
  local key
  for key in "${(@k)OVERRIDES}"; do CFG[$key]="${OVERRIDES[$key]}"; done
}

main() {
  if [[ "${1-}" == preset ]]; then
    shift
    preset_command "$@"
    return
  fi

  parse_args "$@"
  case $? in
    1) return 0 ;;
    2) return 2 ;;
  esac

  mkdir -p "$IN_DIR" "$DONE_DIR" "$LOG_DIR" "$PRESET_DIR"
  read_config
  [[ -n "$PRESET" ]] && { read_preset "$PRESET" || return 2; }
  apply_overrides
  validate_config
  resolve_output_suffix
  [[ -x "$FFMPEG" ]] || {
    log "ffmpeg is not on PATH or in the Homebrew folders"
    return 1
  }

  # Given files (the Finder Quick Action), just optimize those and stop. No files means the
  # folder-watching mode the launchd agent uses.
  if ((${#FILES} > 0)); then
    optimize_files "${FILES[@]}"
    return
  fi

  resolve_output_dir
  acquire_lock || {
    log "another run has the lock, leaving this to it"
    return 0
  }
  process_queue
  check_for_updates
}

trap release_lock EXIT INT TERM
main "$@"
