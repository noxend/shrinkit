#!/bin/zsh
#
# Shrinks screen recordings dropped into the input folder: speeds them up, drops or stretches the
# audio, and re-encodes them small. Settings live in settings.conf next to the folders, so this
# script never needs editing. A launchd WatchPaths agent runs it whenever something lands in
# input/, and running it by hand does exactly the same thing.

set -u
setopt extended_glob

# Every number this script hands to ffmpeg goes through awk, and awk both prints and reads floats
# through the locale: on a machine set to a comma decimal separator, atempo_chain built
# "atempo=1,5000", which ffmpeg read as a filter named 5000, and parse_time read "0:03.5" back as
# plain 3, moving a cut half a second without a word about it. Only the numeric category is pinned,
# so non-ASCII file names keep working. LC_ALL would beat it, so it is moved down to LANG, which
# loses to both, rather than dropped.
if [[ -n "${LC_ALL-}" ]]; then
  export LANG="$LC_ALL"
  unset LC_ALL
fi
export LC_NUMERIC=C

# --------------------------------------------------------------------- where things live

# The path to write down whenever this script has to name itself: in the launchd plist, in a Quick
# Action's command, in the Full Disk Access instructions. ZSH_ARGZERO:A resolves every symlink, so
# under Homebrew it answers with the staged Caskroom/<token>/<version> path, which the next
# `brew upgrade` deletes, taking every Finder entry and the agent with it. It is mapped to
# <prefix>/bin/shrinkit, the link brew repoints at whichever version is current.
self_path() {
  local self="${ZSH_ARGZERO:A}"
  [[ "$self" == */Caskroom/* ]] \
    && print -r -- "${self%/Caskroom/*}/bin/shrinkit" \
    || print -r -- "$self"
}

# Homebrew owns the command on the PATH, so setup makes no link of its own and teardown has nothing
# of brew's to remove.
installed_by_brew() {
  [[ "${ZSH_ARGZERO:A}" == */Caskroom/* ]]
}

# Where presets/ and quick-action/ are read from: beside the script in a checkout or a cask, and
# under ~/.local/share/shrinkit for the copy setup makes of a guarded checkout. SHRINKIT_REPO still wins when it is set at all, so the test
# suite's explicit empty value keeps meaning "no data directory to find".
data_dir() {
  [[ -n "${SHRINKIT_REPO+set}" ]] && {
    print -r -- "$SHRINKIT_REPO"
    return
  }
  local here="${ZSH_ARGZERO:A:h}"
  [[ -d "$here/quick-action" ]] && {
    print -r -- "$here"
    return
  }
  print -r -- "${here:h}/share/shrinkit"
}

# The working folder a user chose, kept in a file rather than only in SHRINKIT_DIR: brew runs its
# install and upgrade scripts with every variable but a handful cleared, so a folder chosen through
# the environment alone was reset to the default on each upgrade. SHRINKIT_DIR still wins when set.
FOLDER_FILE="$HOME/Library/Application Support/shrinkit/folder"
saved_folder() {
  [[ -r "$FOLDER_FILE" ]] && print -r -- "$(< "$FOLDER_FILE")"
}
save_folder() {
  mkdir -p "${FOLDER_FILE:h}" && print -r -- "$1" > "$FOLDER_FILE"
}
# Whether a working folder can hold what shrinkit writes: made if it is missing, with its
# subfolders, and writable. A folder on a disconnected drive, on a read-only NTFS volume or owned
# by root is not, and registering it leaves an agent watching nothing.
usable_folder() {
  mkdir -p "$1/input" "$1/output" "$1/presets" "$1/.logs" "$1/.processed" 2> /dev/null && [[ -w "$1" ]]
}

# An install older than the folder file names its folder only in the agent's plist, and brew clears
# SHRINKIT_DIR, so the plist is read before the default.
registered_folder() {
  plutil -extract EnvironmentVariables.SHRINKIT_DIR raw -o - \
    "$HOME/Library/LaunchAgents/com.shrinkit.plist" 2> /dev/null
}
BASE_DIR="${SHRINKIT_DIR:-$(saved_folder)}"
BASE_DIR="${BASE_DIR:-$(registered_folder)}"
BASE_DIR="${BASE_DIR:-$HOME/Movies/shrinkit}"
SELF="$(self_path)"
REPO_DIR="$(data_dir)" # where the Quick Action template and the stock presets live
# Installed without a .sh extension so it reads as "shrinkit", not "zsh", in the
# System Settings > Login Items background list.
BIN_DIR="$HOME/.local/bin"
# Where setup puts lib/ and the data when it has to copy the tool out of a guarded checkout, laid
# out the way a Homebrew prefix is. Named here rather than inside setup_bin, because teardown has
# to remove exactly what setup wrote.
SHARE_DIR="$HOME/.local/share/shrinkit"

# What this script is called from the outside: the path written into the launchd plist, into every
# Quick Action, and into the Full Disk Access instructions. Read afresh each time one is written,
# since setup makes the link a step before it builds them. A checkout is reached through the link
# setup puts on the PATH, so the name stays "shrinkit" and a git pull needs no reinstall; under
# Homebrew setup makes no link, so there self_path answers.
# macOS keeps Desktop, Documents and Downloads behind a privacy wall. Nothing running without that
# grant can read a file inside one, which covers the launchd agent and every Finder entry.
# Both sides resolved, since the caller's path usually is and $HOME usually is not: a home
# directory behind a symlink of its own spells the same folder two ways and the guard misses,
# which is the mistake setup_bin already carries its own comment about.
guarded_path() {
  local here="${1:A}" home="${HOME:A}"
  case "$here" in
    "$home/Desktop" | "$home/Documents" | "$home/Downloads") return 0 ;;
    "$home/Desktop"/* | "$home/Documents"/* | "$home/Downloads"/*) return 0 ;;
  esac
  return 1
}

registered_path() {
  local link="$BIN_DIR/shrinkit"
  # The PATH entry when it is this script, and also when this script sits where the agent and the
  # Finder entries cannot read it: there setup leaves a copy rather than a link, so the two are no
  # longer the same file and naming $SELF would register something nothing can open.
  if [[ -x "$link" ]] && { [[ "${link:A}" == "$SELF" ]] || guarded_path "$SELF"; }; then
    print -r -- "$link"
    return
  fi
  print -r -- "$SELF"
}

# Where the two biggest self-contained features live: beside the script, or under
# ~/.local/share/shrinkit for the copy of a guarded checkout. Deliberately not data_dir(): SHRINKIT_REPO names where the
# presets and the menu template are, which the test suite blanks on purpose, and code is not that.
lib_dir() {
  local here="${ZSH_ARGZERO:A:h}"
  [[ -d "$here/lib" ]] && {
    print -r -- "$here/lib"
    return
  }
  print -r -- "${here:h}/share/shrinkit/lib"
}
LIB_DIR="$(lib_dir)"

# A missing part is a broken install, not a missing feature, so it stops here. Reported to stderr
# and by exit code rather than to the log, which lives under a folder these parts help set up.
for _part in merge setup doctor edit; do
  [[ -r "$LIB_DIR/$_part.zsh" ]] || {
    print -u2 -r -- "shrinkit is incomplete: cannot read $LIB_DIR/$_part.zsh"
    exit 1
  }
  source "$LIB_DIR/$_part.zsh"
done
unset _part

IN_DIR="$BASE_DIR/input"        # the watched folder
DONE_DIR="$BASE_DIR/.processed" # originals end up here after a good encode
LOG_DIR="$BASE_DIR/.logs"
LOG="$LOG_DIR/optimizer.log"
# Recordings whose result was made but which could not be filed away; see already_done().
STUCK_FILE="$LOG_DIR/stuck"
# Recordings a run in input/ could not shrink, written down the same way; see failed_before().
FAILED_FILE="$LOG_DIR/failed"
LOCK_DIR="$BASE_DIR/.optimizer.lock"

CONFIG="$BASE_DIR/settings.conf"
# named variations on the config, one file each
PRESET_DIR="$BASE_DIR/presets"
# Presets taken out of the right-click menu with 'preset remove', one name per line. setup builds
# an entry for every other preset; without the list it built these again on every run, which brew
# does on every upgrade.
MENU_OFF="$PRESET_DIR/.not-in-menu"

OUT_DIR="$BASE_DIR/output"

# First hit wins: whatever is on PATH, then the two usual Homebrew prefixes. SHRINKIT_TOOL_DIRS,
# colon-separated like PATH, replaces the prefixes for the tests: the machine running them has
# ffmpeg in one, and a missing ffmpeg cannot be made there any other way.
TOOL_DIRS=(${(s.:.)SHRINKIT_TOOL_DIRS:-/opt/homebrew/bin:/usr/local/bin})
find_tool() {
  local name="$1" candidate
  for candidate in "$(command -v "$name" 2> /dev/null)" "${^TOOL_DIRS[@]}/$name"; do
    [[ -x "$candidate" ]] && {
      print -r -- "$candidate"
      return
    }
  done
}
FFMPEG="$(find_tool ffmpeg)"
FFPROBE="$(find_tool ffprobe)"

# The terminal an edit run shows its log on, as a file descriptor: a copy of its stdout taken before
# any $(...) capture, so a line logged inside one still reaches the screen. Empty outside a run.
SCREEN_FD=""

log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"
  # The filter graph is for reading a cut back in the log, not for reading along.
  [[ -n "$SCREEN_FD" && "$*" != graph\ * ]] && print -r -u "$SCREEN_FD" -- "  $*"
  return 0
}

# The part being written and the ffmpeg writing it, so an interrupted run can stop both.
CURRENT_PART=""
CURRENT_CHILD=""

# zsh runs a trap only once a foreground child exits, and launchd kills the agent five seconds after
# asking it to stop, so ffmpeg runs in the background and is waited for: the trap then runs at once
# and can stop it.
run_ffmpeg() {
  local rc
  "$FFMPEG" "$@" &
  CURRENT_CHILD=$!
  wait "$CURRENT_CHILD"
  rc=$?
  CURRENT_CHILD=""
  return $rc
}

# Where ffmpeg writes before the result is moved into place. A right-click entry may create, rename
# and delete its own files in Desktop, Documents and Downloads, but not rename or delete one ffmpeg
# created there, so the part is written in the temporary folder and moved in finished.
# Only when the temporary folder is on the destination's volume: across volumes a move is a copy,
# visible under the final name while it runs, so there the part is hidden beside the result.
# Desktop, Documents and Downloads are on the temporary folder's volume.
# The agent runs without TMPDIR, and /tmp is shared by every account on the Mac, so a name there
# can be planted in advance; the per-user temporary folder cannot.
temp_folder() {
  local tmp="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2> /dev/null)}"
  print -r -- "${${tmp:-/tmp}%/}"
}

temp_part() {
  local dir="$1" tmp dev_tmp dev_dir
  tmp="$(temp_folder)"
  dev_tmp="$(stat -f %d "$tmp" 2> /dev/null)"
  dev_dir="$(stat -f %d "$dir" 2> /dev/null)"
  # Beside only when the devices are known to differ: a folder that will not even answer stat is a
  # guarded one, and those are on the temporary folder's volume.
  if [[ -z "$dev_dir" || "$dev_tmp" == "$dev_dir" ]]; then
    print -r -- "$tmp/shrinkit.$$.$2.part.$3"
  else
    print -r -- "$dir/.$2.$$.part.$3"
  fi
}

# A name nothing holds yet: the one asked for, else with the time added, else with the time and
# the pid. Wherever a second file of the same name must not replace the first. The time goes in
# front of the extension, or of the one named (edit.txt), so a name keeps what it ends in.
free_name() {
  local want="$1" ext stem stamp
  ext="${2:-${want:e}}"
  stem="${want%.$ext}"
  [[ -e "$want" ]] || {
    print -r -- "$want"
    return
  }
  stamp="$(date +%s)"
  [[ -e "$stem-$stamp.$ext" ]] || {
    print -r -- "$stem-$stamp.$ext"
    return
  }
  print -r -- "$stem-$stamp-$$.$ext"
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
  max_height 0       # downscale tall videos, 0 keeps the original size
  keep_original true # move the source aside instead of deleting it
  keep_days 0        # prune .processed/ older than this many days, 0 keeps it forever
  notify true
  notify_start true  # also show a quiet banner when a file starts, not just when it finishes
  notify_sound Glass # any /System/Library/Sounds name, or none
  copy_to_clipboard false
)
typeset -A CFG
CFG=("${(@kv)DEFAULTS}")
# What the config file asked for on a key whose value did not survive validation, so "config" can
# show the value that is really in effect and still say what was in the file.
typeset -A IGNORED

trim() {
  print -r -- "${${1##[[:space:]]#}%%[[:space:]]#}"
}

# A whole line starting with # is a comment; a # elsewhere is part of the value. The last line
# counts without a line break after it, and a byte-order mark an editor put in front of the first
# line is not part of its key: a file that ends on a setting, or was saved as "UTF-8 with BOM", lost
# that setting without a word.
read_settings() {
  local line key value n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++n))
    ((n == 1)) && line="${line#$'\xef\xbb\xbf'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == '#'* ]] && continue
    [[ "$line" == *=* ]] || {
      log "ignoring ${1:t} line $n: '$line' has no '='"
      continue
    }
    key="${(L)${line%%=*}//[[:space:]]/}"
    value="$(trim "${line#*=}")"
    # A key that is not in DEFAULTS is dropped on purpose, which is what keeps a typo harmless.
    # Logged all the same: a setting that used to work and quietly stopped, output_suffix say,
    # otherwise leaves the file looking as if it still does something.
    if [[ -n "${DEFAULTS[$key]+known}" ]]; then
      CFG[$key]="${value//\"/}"
    else
      log "ignoring '$key' in ${1:t} line $n: not a setting"
    fi
  done < "$1"
}

read_config() {
  [[ -f "$CONFIG" ]] && read_settings "$CONFIG"
  return 0
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
  # [.] not \., which [[ =~ ]] strips to a bare . (any character) before the regex ever sees it,
  # so "4-4" or "4X4" would otherwise pass as a number.
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}
is_bool() {
  [[ "$1" == true || "$1" == false ]]
}

# One key's rule, asked about one value, with the words that describe the rule living in the same
# arm. Written this way so "config" can check a single value before writing it and before showing
# it, without any of these ranges being spelled out in a second or third place. Prints the reason
# and returns non-zero when the value does not fit; says nothing when it does.
check_setting() {
  local key="$1" value="$2" reason=
  case "$key" in
    speed)
      reason="want a number above 0"
      is_num "$value" && awk -v s="$value" 'BEGIN { exit !(s > 0) }' && return 0
      ;;
    fps)
      # Capped, so a mistyped value cannot hang the encode. Digit count bounded first for the same
      # reason keep_days bounds it below: zsh arithmetic truncates a long enough digit string to
      # something negative and prints its own diagnostic doing it, so a bare comparison both passes
      # the value and leaks "number truncated after 19 digits" to whoever ran the command.
      reason="want 0-240"
      [[ "$value" =~ ^[0-9]{1,4}$ ]] && ((value <= 240)) && return 0
      ;;
    crf)
      reason="want 0-51"
      [[ "$value" =~ ^[0-9]{1,4}$ ]] && ((value <= 51)) && return 0
      ;;
    max_height)
      reason="want a whole number"
      is_int "$value" && return 0
      ;;
    codec)
      reason="want h264 or hevc"
      [[ "$value" == h264 || "$value" == hevc ]] && return 0
      ;;
    keep_days)
      # The digit count is bounded before the value ever reaches zsh arithmetic: a long enough
      # digit string gets silently truncated there rather than rejected, and could slip through a
      # bare <=3650 comparison at the wrong truncated value. Capped well short of where
      # keep_days*86400 overflows and wraps the cutoff into the future, which would prune
      # everything in .processed/ in one pass, freshly-archived files included.
      reason="want 0-3650"
      [[ "$value" =~ ^[0-9]{1,4}$ ]] && ((value <= 3650)) && return 0
      ;;
    remove_audio | keep_original | notify | notify_start | copy_to_clipboard)
      reason="want true or false"
      is_bool "$value" && return 0
      ;;
    *)
      # notify_sound and anything added later. The sound is looked up by macOS at banner time and
      # a miss is silent, so there is nothing there worth refusing; a new setting that does need a
      # rule gets an arm of its own above.
      return 0
      ;;
  esac
  print -r -- "$reason"
  return 1
}

# Put one setting back to its default and say so, so a bad value never stops a run. What the file
# asked for is kept, because "config" has to be able to show both.
reject() {
  local key="$1" reason="$2"
  log "ignoring $key='${CFG[$key]}' ($reason), using '${DEFAULTS[$key]}'"
  IGNORED[$key]="${CFG[$key]}"
  CFG[$key]="${DEFAULTS[$key]}"
}

# Ordered, not the bare key expansion: an unordered loop would shuffle these log lines from one
# run to the next for no reason.
validate_config() {
  local key reason
  for key in "${(@ko)DEFAULTS}"; do
    reason="$(check_setting "$key" "${CFG[$key]}")" || reject "$key" "$reason"
  done
}

# What a shrunk <name>.mov is called: named after the preset that ran, so the file says which one
# it was, and a plain <name>.mp4 when no preset was named at all.
output_name() {
  [[ -n "$PRESET" ]] && print -r -- "${1:t:r}-${PRESET}.mp4" || print -r -- "${1:t:r}.mp4"
}

# --------------------------------------------------------------------- macOS niceties

# Banner text and sound are configurable; the icon is not, macOS pins it to Script Editor's.
notify() {
  [[ "${CFG[notify]}" == true ]] || return 0
  local message="$1" title="${2:-shrinkit}" sound="${3-${CFG[notify_sound]}}"
  [[ "$sound" == none ]] && sound=""
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
  notify "$1" "${2:-Optimizing…}" none
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

# One whole number off the first video stream, or the fallback when it cannot be read.
video_dimension() {
  local file="$1" entry="$2" fallback="$3" value
  value="$("$FFPROBE" -v error -select_streams v:0 -show_entries "stream=$entry" \
    -of default=nw=1:nk=1 "$file" 2> /dev/null | head -1)"
  is_int "$value" && print -r -- "$value" || print -r -- "$fallback"
}

video_height() {
  video_dimension "$1" height 1080
}

video_width() {
  video_dimension "$1" width 1920
}

# How long a file says it is, or nothing at all when it does not say. Merging needs that "nothing":
# a silent track or a length check built on a made-up number is worse than not being built.
clip_duration() {
  local dur
  dur="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2> /dev/null)"
  is_num "$dur" && print -r -- "$dur"
}

# Cutting needs the opposite answer: a lookup failure returns a very large number rather than 0, so
# a cuts range near the real end of a file whose duration could not be read still gets its trailing
# stretch instead of losing it.
video_duration() {
  local dur
  dur="$(clip_duration "$1")"
  [[ -n "$dur" ]] && print -r -- "$dur" || print -r -- 999999
}

has_audio() {
  [[ -n "$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
    -of csv=p=0 "$1" 2> /dev/null | head -1)" ]]
}

# Cutting every remaining frame out (an over-wide cut, or one that spans the whole clip) leaves
# ffmpeg exiting 0 over an empty, unplayable file. Checked before that file is ever promoted to
# $out, so it is never mistaken for a successful shrink and the source never moved or deleted for it.
has_frames() {
  [[ "$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=duration \
    -of default=nw=1:nk=1 "$1" 2> /dev/null)" =~ ^[0-9] ]]
}

human_size() {
  du -h "$1" | cut -f1 | tr -d ' '
}

# "1:05.5" or "65.5", either way to seconds. Prints nothing for anything else.
parse_time() {
  local t="$1"
  if [[ "$t" == *:* ]]; then
    # OFMT: awk's default (%.6g) rounds a long fraction to 6 significant digits, so "16:40.333333"
    # would come out as 1000.33 instead of 1000.333333 -- harmless at a recording's usual length,
    # but needless, and it would start to matter past roughly 2.7 hours (10000s) of mm:ss input.
    awk -v t="$t" 'BEGIN {
      OFMT = "%.9g"
      if (t ~ /^[0-9]+:[0-9]+(\.[0-9]+)?$/) { n = split(t, p, ":"); print p[1] * 60 + p[2] }
    }'
  elif is_num "$t"; then
    print -r -- "$t"
  fi
}

# One "start-end" range to a "start end" pair in seconds, or nothing plus a log line saying why it
# was rejected. where names the range's origin for that log line: the flag it came from, or
# RANGE_ORIGIN when that is set. kind is "cut" or "keep", and changes only how a
# rejection reads: a range is a range, and parses the same either way. duration is the source's
# real length (video_duration()'s output), used to resolve "end" and to catch a range that starts
# at or past it.
parse_range() {
  local line="$1" duration="$2" where="$3" kind="$4" shown start end
  shown="${line:0:80}"
  start="$(trim "${line%%-*}")"
  end="$(trim "${line#*-}")"
  start="$(parse_time "$start")"
  # "end" reaches the real length without knowing it -- a bare trailing dash would do the same
  # and never be confused with a negative number (nothing follows it to negate), but a bare
  # leading dash would: "-0:20" reads exactly like negative twenty seconds to anyone who has not
  # read this file's own rules first. "0-0:20" already means "from the start" on its own, so the
  # start side gets no shorthand at all, only the end side does, and it is a real word, not a
  # punctuation trick.
  [[ "${(L)end}" == end ]] && end="$duration" || end="$(parse_time "$end")"
  if [[ -z "$start" || -z "$end" ]] || ! awk -v a="$start" -v b="$end" 'BEGIN { exit !(b > a) }'; then
    # TextEdit's Smart Dashes turns a typed "-" into an en dash the split above never sees, so the
    # line reads as one blob with no separator at all -- worth naming, since it looks nothing like
    # a formatting mistake to whoever typed it.
    if [[ "$line" == *[–—]* && "$line" != *-* ]]; then
      log "ignoring $kind '$shown' $where (looks like a smart dash -- turn off Smart Dashes in TextEdit's Edit > Substitutions, or retype the -)"
    else
      log "ignoring $kind '$shown' $where (want start-end, end after start)"
    fi
    return 1
  fi
  # Under one frame interval at any fps this tool allows (fps <= 240, 1 frame = ~4ms) can match
  # no real frame at all, cutting nothing while still being logged and reported as a success. The
  # 1e-9 slack is so a range typed as exactly 0.1s (e.g. 6.0-6.1) is not rejected over IEEE-754
  # double subtraction landing a hair under 0.1 for some perfectly ordinary decimal pairs.
  if ! awk -v a="$start" -v b="$end" 'BEGIN { exit !(b - a >= 0.1 - 1e-9) }'; then
    log "ignoring $kind '$shown' $where (too short to reliably $kind, want at least 0.1s)"
    return 1
  fi
  # Entirely past the end cuts nothing at all -- ffmpeg's own trim= just clamps to the real
  # length, so without this check the range gets accepted, reported as "cut applied", and the
  # source ships untouched. A range that only starts before the end and overruns past it is real
  # and left alone; only "starts at or after the end" means nothing survives to be cut. A keep
  # range out there is the same mistake seen from the other side: it selects no footage at all.
  if awk -v a="$start" -v b="$duration" 'BEGIN { exit !(a >= b) }'; then
    local outcome="nothing to cut"
    [[ "$kind" == keep ]] && outcome="no footage there to keep"
    log "ignoring $kind '$shown' $where (starts at or after the clip's real length, ${duration}s -- $outcome)"
    return 1
  fi
  print -r -- "$start $end"
}

# The ranges to cut, from --keep or --cut. Prints them as sorted, merged "start end" pairs, one per
# line in seconds, or nothing if neither was named or nothing valid was in them. A bad range is
# skipped and logged rather than spoiling the ones around it.
read_cuts() {
  local duration="$1" line pair
  local -a pairs
  # --keep names the footage to survive, so the ranges to cut are what it leaves out: the same
  # pairs, complemented against the real length. Everything downstream of here is the cut path
  # unchanged, since a keep is only ever a cut described from the other side.
  if ((${#KEEP_RANGES} > 0)); then
    for line in "${KEEP_RANGES[@]}"; do
      pair="$(parse_range "$line" "$duration" "${RANGE_ORIGIN:-from --keep}" keep)" && pairs+=("$pair")
    done
    ((${#pairs} > 0)) || return 0
    local complemented
    complemented="$(printf '%s\n' "${pairs[@]}" | sort -n -k1,1 | merge_cut_ranges \
      | complement_ranges "$duration" | drop_uncuttable_gaps)"
    [[ -n "$complemented" ]] && {
      print -r -- "$complemented"
      return 0
    }
    # Every range was good, they just leave nothing between them to cut. 2, since cuts_note() would
    # otherwise read the empty output as "every range was rejected" and send the user to the log.
    return 2
  fi
  for line in "${CUT_RANGES[@]}"; do
    pair="$(parse_range "$line" "$duration" "${RANGE_ORIGIN:-from --cut}" cut)" && pairs+=("$pair")
  done
  # 0 even when no range was usable: cuts_note() reads the flags to tell that from no cut asked.
  ((${#pairs} > 0)) && printf '%s\n' "${pairs[@]}" | sort -n -k1,1 | merge_cut_ranges
  return 0
}

# Sorted "start end" pairs in, one per line on stdin; merges any that touch or overlap so two
# ranges given separately can never leave a keep-segment with a negative length.
merge_cut_ranges() {
  awk '
    NR == 1 { s = $1; e = $2; next }
    $1 <= e { if ($2 > e) e = $2; next }
    { print s, e; s = $1; e = $2 }
    END { if (NR > 0) print s, e }
  '
}

# ", cut applied" once at least one range took; ", cut requested but none applied" when --cut or
# --keep named ranges and every one of them was rejected; empty when no cut was asked for.
cuts_note() {
  local cuts="$1" rc="$2" asked=cut
  # 2 is read_cuts() saying every --keep range was good and together they cover the whole clip.
  # Nothing is left to cut, and nothing went wrong, so it must not read like a rejected range.
  [[ "$rc" -eq 2 ]] && {
    print -r -- ", kept the whole clip, nothing to cut"
    return 0
  }
  ((${#KEEP_RANGES} > 0)) && asked=keep
  ((${#CUT_RANGES} > 0)) || ((${#KEEP_RANGES} > 0)) || return 0
  [[ -n "$cuts" ]] && print -r -- ", cut applied" || print -r -- ", $asked requested but none applied -- see the log"
}

# Cut pairs on stdin -> the same pairs, minus any too short to land on a real frame. The gaps
# between --keep ranges are cut ranges nobody typed, so they never passed parse_range's own
# minimum-length check: two keeps a few milliseconds apart come out as a cut that removes no frame
# at all while still being reported as a cut applied, which is the outcome that check exists to
# prevent. Dropping the gap joins the two keeps, which is what ranges that close together mean.
drop_uncuttable_gaps() {
  local start end
  while IFS=' ' read -r start end; do
    [[ -n "$start" ]] || continue
    if awk -v a="$start" -v b="$end" 'BEGIN { exit !(b - a >= 0.1 - 1e-9) }'; then
      print -r -- "$start $end"
    else
      log "joining the keeps around ${start}-${end}: the gap between them is under the 0.1s a cut needs"
    fi
  done
}

# Sorted, merged "start end" pairs on stdin and the source's real duration in -> the stretches they
# leave out, same format, bounded by the real duration. Cut and keep are each other's complement,
# so this runs both ways round: cut ranges in gives the stretches to keep, keep ranges in gives the
# ranges to cut. With "open-tail", a stretch that runs to the real end is printed with no end of
# its own, which is what the filter graph wants and what a range fed back through here is not.
complement_ranges() {
  local duration="$1" tail_style="${2-}" start end prev=0
  while IFS=' ' read -r start end; do
    [[ -n "$start" ]] || continue
    awk -v a="$prev" -v b="$start" 'BEGIN { exit !(b > a) }' && print -r -- "$prev $start"
    prev="$end"
  done
  if awk -v a="$prev" -v b="$duration" 'BEGIN { exit !(b > a) }'; then
    [[ "$tail_style" == open-tail ]] && print -r -- "$prev " || print -r -- "$prev $duration"
  fi
}

# The stretches to KEEP, from the cut ranges: complement_ranges() with the trailing stretch left
# open, so trim= reads it as "through the end of the clip" rather than as a timestamp of its own.
# Bounded by the real duration either way, so a cut reaching at or past it never adds an empty
# trailing stretch: concat tolerates one, but fps= downstream of it does not -- measured, it
# stretched a 6.9s result out to 9.3s instead of leaving it alone.
keep_ranges() {
  complement_ranges "$1" open-tail
}

# Builds the -filter_complex graph for a set of cut ranges: each surviving stretch is trimmed and
# has its own timestamps rebased to start at PTS 0, then the stretches are concatenated back
# together. No step here assumes a constant frame rate anywhere, unlike the select()+
# setpts=N/FRAME_RATE/TB this replaced, which played 2-3x too fast on the variable frame rate
# ReplayKit actually records at (measured: a select() that dropped zero frames still compressed a
# 24.6s clip to 7.8s). Ends in [vout], and [aout] too when keep_audio is true. Empty means the cuts
# leave nothing to keep.
cut_filter_graph() {
  local cuts="$1" height="$2" keep_audio="$3" duration="$4"
  local -a segments vchains achains
  local start end i n

  segments=("${(@f)$(keep_ranges "$duration" <<< "$cuts")}")
  n="${#segments}"
  ((n > 0)) || return 0

  # trim keeps or drops whole frames by where they start, not by the second, so a frame held for
  # seconds (ordinary for a mostly-static screen recording) survives a cut boundary landing inside
  # it in full, pushing the real cut point out by however long that held frame was. Resampling to a
  # steady rate before any trim runs bounds that to a single frame, the same margin read_cuts()
  # already assumes elsewhere.
  local cutfps=$((CFG[fps] > 0 ? CFG[fps] : 30))

  # A plain shared [vnorm] read by more than one filter looked fine but was not: ffmpeg only ever
  # handed the fps-normalized stream to the FIRST filter that read the label, silently handing every
  # later cut segment the raw, un-normalized frames instead -- reopening the bug directly above for
  # every keep segment but the first. split= is the explicit fan-out ffmpeg actually needs here.
  local vnormlabels=""
  for ((i = 0; i < n; i++)); do vnormlabels="${vnormlabels}[vnorm$i]"; done
  local pre="[0:v]fps=${cutfps},split=${n}${vnormlabels};"

  for ((i = 0; i < n; i++)); do
    start="${segments[i + 1]%% *}"
    end="${segments[i + 1]#* }"
    if [[ -z "$end" ]]; then
      vchains+=("[vnorm$i]trim=start=${start},setpts=PTS-STARTPTS[v$i]")
      achains+=("[0:a]atrim=start=${start},asetpts=PTS-STARTPTS[a$i]")
    else
      vchains+=("[vnorm$i]trim=start=${start}:end=${end},setpts=PTS-STARTPTS[v$i]")
      achains+=("[0:a]atrim=start=${start}:end=${end},asetpts=PTS-STARTPTS[a$i]")
    fi
  done

  local -a vtail
  ((CFG[max_height] > 0 && height > CFG[max_height])) && vtail+=("scale=-2:${CFG[max_height]}")
  vtail+=("setpts=PTS/${CFG[speed]}")
  # Speeding up after the trims changes the real frame density (2x speed roughly doubles it), so the
  # configured cap has to be re-applied here too, the same as video_filters() already does for a run
  # with no cuts at all -- otherwise "fps" stops being a cap the moment a cut is involved.
  ((CFG[fps] > 0)) && vtail+=("fps=${CFG[fps]}")

  local vlabels="" alabels=""
  for ((i = 0; i < n; i++)); do
    vlabels="${vlabels}[v$i]"
    alabels="${alabels}[a$i]"
  done

  local graph="${pre}${(j:;:)vchains};${vlabels}concat=n=${n}:v=1:a=0[vcut];[vcut]${(j:,:)vtail}[vout]"
  [[ "$keep_audio" == true ]] \
    && graph="${graph};${(j:;:)achains};${alabels}concat=n=${n}:v=0:a=1[acut];[acut]$(atempo_chain "${CFG[speed]}")[aout]"
  print -r -- "$graph"
}

# No cuts: the plain per-file filters, unchanged by anything above.
video_filters() {
  local height="$1" chain=""
  ((CFG[max_height] > 0 && height > CFG[max_height])) && chain="scale=-2:${CFG[max_height]},"
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

# Non-zero means ffmpeg failed and nothing was written to $out. cuts is read_cuts()'s output,
# passed in rather than read here so a caller can also use it to decide what to tell the user.
encode() {
  local src="$1" out="$2" cuts="$3" height keep_audio=false
  height="$(video_height "$src")"

  local -a audio codec filter_args
  if [[ "${CFG[remove_audio]}" == true ]] || ! has_audio "$src"; then
    audio=(-an)
  else
    keep_audio=true
  fi

  if [[ "${CFG[codec]}" == hevc ]]; then
    codec=(-c:v libx265 -tag:v hvc1)
  else
    codec=(-c:v libx264)
  fi
  codec+=(-crf "${CFG[crf]}" -preset veryfast)

  local label="${height}p, ${CFG[speed]}x, ${CFG[fps]}fps, ${CFG[codec]} crf${CFG[crf]}"
  [[ -n "$cuts" ]] && label="$label, cut"

  if [[ -n "$cuts" ]]; then
    local graph
    graph="$(cut_filter_graph "$cuts" "$height" "$keep_audio" "$(video_duration "$src")")"
    if [[ -z "$graph" ]]; then
      log "FAILED ${src:t}: nothing was left to encode (a cut may remove the whole clip)"
      return 1
    fi
    # The one part of a cut run the log would otherwise never show: ffmpeg echoes its inputs and
    # its stream mapping, never the graph it was handed, so a cut landing somewhere unexpected
    # cannot be told from a graph built wrong.
    log "graph  ${src:t}: $graph"
    filter_args=(-filter_complex "$graph" -map '[vout]')
    if [[ "$keep_audio" == true ]]; then
      filter_args+=(-map '[aout]')
      # -shortest: video is quantized to whole frames, audio to AAC's own frame size, so the two
      # round a cut boundary slightly differently. Harmless alone; -shortest keeps it from adding up.
      audio=(-c:a aac -b:a 128k -shortest)
    fi
  else
    filter_args=(-filter:v "$(video_filters "$height")")
    [[ "$keep_audio" == true ]] && audio=(-c:a aac -b:a 128k -filter:a "$(atempo_chain "${CFG[speed]}")" -shortest)
  fi

  # Written to a temp file first, so two runs on one name can never collide mid-write.
  local part
  part="$(temp_part "${out:h}" "${out:t:r}" mp4)"
  CURRENT_PART="$part"

  log "encode ${src:t} ($label)"
  run_ffmpeg -nostdin -y -i "$src" "${filter_args[@]}" \
    "${audio[@]}" "${codec[@]}" -pix_fmt yuv420p -movflags +faststart \
    "$part" >> "$LOG" 2>&1 || {
    rm -f "$part"
    return 1
  }
  has_frames "$part" || {
    log "FAILED ${src:t}: nothing was left to encode (a cut may remove the whole clip)"
    rm -f "$part"
    return 1
  }
  mv -f "$part" "$out" 2>> "$LOG" || {
    log "FAILED ${src:t}: could not move ${out:t} into ${out:h} (the reason is on the line above)"
    rm -f "$part"
    return 1
  }
  CURRENT_PART=""
}

# The size line, clipboard copy and finished banner, shared by both modes. note is cuts_note()'s
# output, if any -- e.g. ", cut applied" -- folded in the same way the clipboard note already is.
announce() {
  local name="$1" out="$2" before="$3" after="$4" extra="${5:-}"
  if [[ "${CFG[copy_to_clipboard]}" == true ]]; then
    copy_to_clipboard "$out"
    extra="${extra}, copied to clipboard"
  fi
  log "done   ${out:t} ($before -> $after)$extra"
  notify "$name   $before -> $after$extra"
}

# Shrink one file. archive=true files the source away afterwards (folder mode); false leaves it
# where it is (the Finder Quick Action). Non-zero means nothing was written and the source is
# untouched either way.
shrink() {
  local src="$1" out="$2" archive="$3" before after cuts rc note
  before="$(human_size "$src")"
  notify_start "${src:t:r}"
  # A .cuts file is not read since 4.0, and a cut written in one would ship uncut: said until 5.0.
  [[ -f "${src}.cuts" ]] && {
    log "${src:t}.cuts is no longer read; cut with shrinkit: edit or --cut"
    notify "${src:t}.cuts is no longer read; cut with shrinkit: edit or --cut"
  }

  cuts="$(read_cuts "$(video_duration "$src")")"
  rc=$?
  note="$(cuts_note "$cuts" "$rc")"

  encode "$src" "$out" "$cuts" || {
    # A watched file is always in input/; a right-clicked one can be anywhere, so name the path.
    [[ "$archive" == true ]] \
      && log "FAILED ${src:t}, left in place (ffmpeg output is above)" \
      || log "FAILED $src (one-shot, ffmpeg output is above)"
    [[ "$archive" == true ]] && mark_failed "$src"
    notify "${src:t}" "Could not shrink"
    return 1
  }
  after="$(human_size "$out")"

  if [[ "$archive" == true ]]; then
    if [[ "${CFG[keep_original]}" == true ]]; then
      # touch: mv keeps the file's own mtime, but keep_days counts from when it was archived.
      # Under a free name, so a second recording with the same name does not replace the first.
      local kept
      kept="$(free_name "$DONE_DIR/${src:t}")"
      if mv "$src" "$kept" 2>> "$LOG"; then
        touch "$kept"
      else
        mark_stuck "$src"
        log "kept   ${src:t} in input/: it could not be moved to .processed/ (the reason is above)"
      fi
    elif ! rm -f "$src" 2>> "$LOG"; then
      mark_stuck "$src"
      log "kept   ${src:t} in input/: it could not be deleted (the reason is above)"
    fi
  fi
  announce "${src:t:r}" "$out" "$before" "$after" "$note"
}

# One-shot mode (the Finder Quick Action): write the result next to each source, originals alone.
optimize_files() {
  local src out
  for src in "$@"; do
    # Said on the terminal as well as in the log: a mistyped command lands here as a file name.
    [[ -f "$src" ]] || {
      log "skip   $src (not a file)"
      print -u2 -r -- "'$src' is not a file or a command (see --help)"
      continue
    }
    # The right-click menu only offers video files, but a text file beside a recording is easy to
    # select along with it. Without this, encode() would be handed it and fail with a "could not
    # shrink" banner naming that file, not the video.
    [[ "$src" == (#i)*.(mov|mp4|m4v) ]] || {
      log "skip   ${src:t} (not a video)"
      print -u2 -r -- "${src:t} is not a video (.mov, .mp4 or .m4v)"
      continue
    }
    out="${src:h}/$(output_name "$src")"
    out="$(free_name "$out")"
    shrink "$src" "$out" false
  done
}

# A recording that stays in input/ after its result was made, because it could not be moved to
# .processed/ or deleted, is written down by what it is rather than by name or time: device, inode
# and size. A later recording with the same name is a different file, and times cannot tell them
# apart on every volume (exFAT keeps the copied modification time as the change time).
source_id() {
  stat -f '%d:%i:%z' "$1" 2> /dev/null
}
mark_stuck() {
  source_id "$1" >> "$STUCK_FILE"
}
already_done() {
  local id
  id="$(source_id "$1")"
  [[ -n "$id" ]] && grep -qxF -- "$id" "$STUCK_FILE" 2> /dev/null
}
# A recording that failed stays in input/ and is tried again with every drop, so it is written down
# once, for doctor to say which one it is without reading the log's wording.
mark_failed() {
  failed_before "$1" || source_id "$1" >> "$FAILED_FILE"
}
failed_before() {
  local id
  id="$(source_id "$1")"
  [[ -n "$id" ]] && grep -qxF -- "$id" "$FAILED_FILE" 2> /dev/null
}

# Re-scans after every file: launchd swallows drop events while a run is already in progress.
process_queue() {
  local -a pending
  local src out progressed=1 seen=0

  while ((progressed)); do
    progressed=0
    pending=("$IN_DIR"/(#i)*.(mov|mp4|m4v)(N.))
    for src in "${pending[@]}"; do
      seen=1
      out="$OUT_DIR/$(output_name "$src")"
      if already_done "$src"; then
        log "skip   ${src:t} (already has an optimized copy)"
      elif [[ ! -s "$src" ]]; then
        log "skip   ${src:t} (empty: nothing to shrink yet)"
      elif ! is_settled "$src"; then
        log "skip   ${src:t} (still being written)"
      elif shrink "$src" "$(free_name "$out")" true; then
        progressed=1
      fi
    done
  done

  ((seen)) || log "nothing new to do"
}

# Epoch seconds, not zsh's (m+N): that counts calendar days, not 24h spans, and misjudged a 25h file here.
prune_processed() {
  ((CFG[keep_days] > 0)) || return 0
  local cutoff=$(($(date +%s) - CFG[keep_days] * 86400)) file mtime
  for file in "$DONE_DIR"/*(N.); do
    mtime="$(stat -f%m "$file" 2> /dev/null)" || continue
    ((mtime < cutoff)) && rm -f "$file" && log "pruned ${file:t} (older than ${CFG[keep_days]}d)"
  done
}

# --------------------------------------------------------------------- run

# mkdir is atomic; the pid inside says who holds it, so a dead owner's lock can be taken over.
LOCK_HELD=0
LOCK_PID_FILE="$LOCK_DIR/pid"

# Alive and a run: zsh running shrinkit. A run stopped without cleaning up leaves its pid behind,
# and once macOS hands that number to another program, a check for "alive" alone left the lock
# held for good and every later run standing down.
lock_owner_alive() {
  local owner
  owner="$(cat "$LOCK_PID_FILE" 2> /dev/null)"
  is_int "$owner" && kill -0 "$owner" 2> /dev/null || return 1
  [[ "$(ps -o comm= -p "$owner" 2> /dev/null)" == (*/|)zsh ]] \
    && [[ "$(ps -o command= -p "$owner" 2> /dev/null)" == *shrinkit* ]]
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

# --------------------------------------------------------------------- the config subcommand

# What a run would use, not what the file says: validate_config has already put any value that does
# not fit back to its default, and a key it had to reject says so on its own line. Printing the
# file's own text here let a typo look live while every recording was encoded at the default.
config_show() {
  local key
  for key in "${(@ko)CFG}"; do
    if [[ -n "${IGNORED[$key]+set}" ]]; then
      print -r -- "$key = ${CFG[$key]}   (ignoring '${IGNORED[$key]}' in settings.conf)"
    else
      print -r -- "$key = ${CFG[$key]}"
    fi
  done
}

# Rewrites the one line in place so the comments around it survive; a setting the file never
# mentioned is appended.
config_set() {
  local key="${(L)${1//-/_}}" value="$2" line tmp found=0 reason
  [[ -n "${DEFAULTS[$key]+known}" ]] || {
    print -u2 -r -- "unknown setting: $1"
    return 1
  }
  # The same rule a run applies, applied before the value reaches the file. Writing it first and
  # rejecting it later left settings.conf holding a number no recording would ever be encoded at,
  # while the command that wrote it said nothing.
  reason="$(check_setting "$key" "$value")" || {
    print -u2 -r -- "$key: $reason, not '$value'"
    return 1
  }

  tmp="$(mktemp)"
  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$(trim "$line")" != '#'* && "$(trim "${line%%=*}")" == "$key" ]]; then
        print -r -- "$key = $value"
        found=1
      else
        print -r -- "$line"
      fi
    done < "$CONFIG" > "$tmp"
  fi
  ((found)) || print -r -- "$key = $value" >> "$tmp"

  mv "$tmp" "$CONFIG"
  print -r -- "$key = $value"
}

config_edit() {
  local -a editor
  # zsh does not split an expansion into words on its own, hence the =
  editor=(${=EDITOR:-open -t})
  [[ -f "$CONFIG" ]] || : > "$CONFIG"
  "${editor[@]}" "$CONFIG"
}

# Moving the working folder means a new watch path for the agent, new menu entries and a new
# Desktop shortcut, which is setup's job, so an install that exists is set up again for the new one.
# The files already in the old folder stay there.
config_folder() {
  local new="$1" old_link="$HOME/Desktop/${BASE_DIR:t}"
  [[ -n "$new" ]] || {
    print -r -- "$BASE_DIR"
    return 0
  }
  new="${new:a}"
  usable_folder "$new" || {
    print -u2 -r -- "cannot create or write to $new; nothing was changed"
    return 1
  }
  save_folder "$new" || {
    print -u2 -r -- "could not save the folder to $FOLDER_FILE"
    return 1
  }
  print -r -- "==> Working folder: $new"
  # The settings and presets go along when the new folder has none, since moving the folder is not
  # meant to put every setting back to its default. Recordings and results stay where they are.
  if [[ "$new" != "$BASE_DIR" && -f "$CONFIG" && ! -f "$new/settings.conf" ]]; then
    mkdir -p "$new/presets"
    cp "$CONFIG" "$new/settings.conf"
    cp "$PRESET_DIR"/*.conf(N) "$PRESET_DIR"/.not-in-menu(N) "$new/presets/" 2> /dev/null
    print -r -- "    Brought your settings and presets along."
  fi
  [[ "$new" != "$BASE_DIR" && -d "$BASE_DIR" ]] \
    && print -r -- "    Recordings and results already in $BASE_DIR stay there."
  [[ -f "$PLIST" ]] || return 0
  [[ -L "$old_link" && "$(readlink "$old_link")" == "$BASE_DIR" && "${new:t}" != "${BASE_DIR:t}" ]] \
    && rm -f "$old_link"
  SHRINKIT_DIR="$new" zsh "${ZSH_ARGZERO:A}" setup
}

config_command() {
  # Not for folder: moving away from a folder that was moved or deleted by hand would recreate it.
  [[ "${1-}" == folder ]] || mkdir -p "$BASE_DIR" "$LOG_DIR"
  case "${1-}" in
    "" | show)
      read_config
      validate_config
      config_show
      ;;
    edit)
      config_edit
      ;;
    folder)
      config_folder "${2-}"
      ;;
    *)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: config [show | edit | folder [<path>] | <setting> <value>]"
        return 2
      }
      config_set "$1" "$2" || return 2
      ;;
  esac
}

# --------------------------------------------------------------------- presets

SERVICES_DIR="$HOME/Library/Services"
# Reached through a variable, as launchctl is, so a test refreshes a stub rather than the Services
# menu of the Mac running it.
PBS="${SHRINKIT_PBS:-/System/Library/CoreServices/pbs}"

# Copied rather than built from scratch; any existing menu entry works as the template too.
quick_action_template() {
  local candidate
  for candidate in "$REPO_DIR/quick-action/shrinkit.workflow" "$SERVICES_DIR"/shrinkit*.workflow(N); do
    [[ -d "$candidate" ]] && {
      print -r -- "$candidate"
      return
    }
  done
  return 1
}

# One entry in the right-click menu: the template copied into ~/Library/Services, with the command
# it runs and the name it shows replaced. Every entry differs only in those two. The folder, the
# program and the preset go into that command single-quoted, since zsh runs it: inside double
# quotes a $ or a backtick in a folder or preset name ran as code on every right-click.
install_quick_action() {
  local name="$1" command="$2" template action
  template="$(quick_action_template)" || {
    print -u2 -r -- "cannot find a Quick Action to copy (looked in ${REPO_DIR:-<unset>}/quick-action)"
    return 1
  }

  action="$SERVICES_DIR/shrinkit: $name.workflow"
  mkdir -p "$SERVICES_DIR"
  rm -rf "$action"
  cp -R "$template" "$action"

  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string "$command" \
    "$action/Contents/document.wflow"
  plutil -replace CFBundleName -string "shrinkit: $name" "$action/Contents/Info.plist"
  plutil -replace NSServices.0.NSMenuItem.default -string "shrinkit: $name" \
    "$action/Contents/Info.plist"
  "$PBS" -update 2> /dev/null || true

  print -r -- "right-click a video > shrinkit: $name"
}

install_preset_action() {
  local name="$1"
  [[ -f "$(preset_file "$name")" ]] || {
    print -u2 -r -- "no preset called '$name' (looked in $PRESET_DIR)"
    return 1
  }
  install_quick_action "$name" \
    "SHRINKIT_DIR=${(qq)BASE_DIR} ${(qq)$(registered_path)} --preset ${(qq)name} \"\$@\""
}

remove_preset_action() {
  rm -rf "$SERVICES_DIR/shrinkit: $1.workflow"
  in_menu "$1" && print -r -- "$1" >> "$MENU_OFF"
  "$PBS" -update 2> /dev/null || true
  print -r -- "removed the Quick Action for '$1'"
}

in_menu() {
  ! grep -qxF -- "$1" "$MENU_OFF" 2> /dev/null
}

back_in_menu() {
  local -a off
  [[ -f "$MENU_OFF" ]] || return 0
  off=("${(@f)$(< "$MENU_OFF")}")
  off=("${(@)off:#${(b)1}}")
  if ((${#off})); then
    print -rl -- "${off[@]}" > "$MENU_OFF"
  else
    rm -f "$MENU_OFF"
  fi
}

preset_command() {
  mkdir -p "$PRESET_DIR"
  case "${1-}" in
    install)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: preset install <name>"
        return 2
      }
      install_preset_action "$2" && back_in_menu "$2" || return 2
      ;;
    remove)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: preset remove <name>"
        return 2
      }
      remove_preset_action "$2"
      ;;
    *)
      print -u2 -r -- "usage: preset [install <name>|remove <name>]"
      return 2
      ;;
  esac
}

# mark-cuts went in 4.0, replaced by edit. An entry an older setup built runs it until setup runs
# again, and parse_args would take the word for a file name and shrink the selected recordings.
# A banner as well as stderr, since nothing a Quick Action prints is ever seen. Kept for 4.x.
answer_mark_cuts() {
  local answer="mark-cuts was replaced by edit in shrinkit 4: shrinkit edit <file>... Run 'shrinkit setup' to update the right-click menu."
  mkdir -p "$LOG_DIR"
  read_config
  validate_config
  print -u2 -r -- "$answer"
  log "$answer"
  notify "$answer"
  return 2
}

# --------------------------------------------------------------------- run

usage() {
  print -r -- "usage: ${ZSH_ARGZERO:t} [--setting value ...] [file ...]
       ${ZSH_ARGZERO:t} config [show | edit | folder [<path>] | <setting> <value>]
       ${ZSH_ARGZERO:t} preset [install <name> | remove <name>]
       ${ZSH_ARGZERO:t} merge <file>...
       ${ZSH_ARGZERO:t} setup | teardown
       ${ZSH_ARGZERO:t} doctor

  no files       optimize everything waiting in $IN_DIR
  file ...       optimize those files where they are, next to each source

Every setting is also a flag, so --crf 24 or --speed 3 changes one run without
touching the config. A true/false setting takes no value: --remove-audio turns
it on, --no-remove-audio turns it off.

--cut takes one range, and repeats for more: --cut 0:32-0:35 --cut 2:30-end.
--keep is the same edit from the other side: it names the footage to survive
and cuts everything else, so --keep 1:00-2:00 leaves exactly that minute.
Use one or the other, not both. Either needs the file named, since a
timestamp only means something in one recording.

A preset is a file of the same settings in $PRESET_DIR.
Use one for a run with --preset <name>, or turn it into its own right-click
entry with 'preset install <name>'.

merge joins several recordings into one, in the order they were recorded, or by
a number at the start of the file name (1 intro.mov, 2 bug.mov) for any that
carry one. The result lands beside the first clip and the originals stay where
they are. It does not shrink: run a preset on the result afterwards. Same as the
right-click 'shrinkit: merge' entry.

config folder <path> moves the working folder: the watcher, the right-click
entries and the Desktop shortcut follow, and so do settings.conf and the presets.
Recordings and results already in the old folder stay there.

setup creates the folders, registers the launchd agent that watches input/,
builds the right-click entries and puts shrinkit on your PATH. teardown undoes
all of it and leaves your recordings and settings alone. Homebrew runs both on
install, upgrade and uninstall; run them yourself only from a clone.

doctor looks the install over and says what is wrong with it and what to run
to fix it. It only reads: it changes nothing.

  settings       $CONFIG
  presets        $PRESET_DIR
  log            $LOG"
}

# Every setting doubles as a flag, so there is no explicit list of them here.
typeset -A OVERRIDES
typeset -a FILES
typeset -a CUT_RANGES
typeset -a KEEP_RANGES
# Where the ranges came from, for the log line of one that is rejected; empty means the flags.
RANGE_ORIGIN=""
PRESET=""

# 1 means there is nothing left to do (--help), 2 means the command line was wrong.
parse_args() {
  local arg key flag
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
      # Both repeatable, one range each. --keep is the same argument seen from the other side, so
      # it is parsed the same way and told apart only at the end.
      --cut | --keep)
        flag="$arg"
        shift
        # An empty value is refused rather than skipped: a wrapper expanding a variable it never
        # set is how it happens, and shrinking without the range it meant would keep the footage
        # it was meant to cut. Command-line syntax is checked strictly here; the
        # never-abort-on-one-bad-value convention covers settings lines, not a malformed
        # invocation.
        [[ -n "${1-}" ]] || {
          print -u2 -r -- "$flag needs a range, e.g. $flag 0:32-0:35"
          return 2
        }
        [[ "$flag" == --cut ]] && CUT_RANGES+=("$1") || KEEP_RANGES+=("$1")
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
  case "${1-}" in
    config)
      shift
      config_command "$@"
      return
      ;;
    preset)
      shift
      preset_command "$@"
      return
      ;;
    mark-cuts)
      answer_mark_cuts
      return
      ;;
    merge)
      shift
      merge_command "$@"
      return
      ;;
    edit)
      shift
      edit_command "$@"
      return
      ;;
    run)
      shift
      run_command "$@"
      return
      ;;
    setup)
      shift
      setup_command "$@"
      return
      ;;
    teardown)
      shift
      teardown_command "$@"
      return
      ;;
    doctor)
      shift
      doctor_command "$@"
      return
      ;;
  esac

  parse_args "$@"
  case $? in
    1) return 0 ;;
    2) return 2 ;;
  esac

  # Naming both is a mistake, not a preference to resolve: they describe the same edit from
  # opposite sides, and silently letting one win would cut footage the other line asked to keep.
  if ((${#CUT_RANGES} > 0 && ${#KEEP_RANGES} > 0)); then
    print -u2 -r -- "--cut and --keep are the same edit from opposite sides; use one or the other"
    return 2
  fi

  # A timestamp only means anything against one particular recording, so --cut or --keep with no
  # file named is a forgotten argument rather than a queue-wide instruction. Left to fall through it
  # would take the watch folder's whole backlog, cut the same seconds out of files that never asked
  # for it, and with keep_original = false delete every source it had just cut. Every other flag is
  # safe to apply queue-wide; these are not.
  if ((${#CUT_RANGES} + ${#KEEP_RANGES} > 0 && ${#FILES} == 0)); then
    if ((${#KEEP_RANGES} > 0)); then
      print -u2 -r -- "--keep needs the file to keep from, e.g. shrinkit --keep 1:00-2:00 recording.mov"
    else
      print -u2 -r -- "--cut needs the file to cut, e.g. shrinkit --cut 0:32-0:35 recording.mov"
    fi
    return 2
  fi

  mkdir -p "$IN_DIR" "$OUT_DIR" "$DONE_DIR" "$LOG_DIR" "$PRESET_DIR"
  read_config
  [[ -n "$PRESET" ]] && { read_preset "$PRESET" || return 2; }
  apply_overrides
  validate_config
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

  acquire_lock || {
    log "another run has the lock, leaving this to it"
    return 0
  }
  process_queue
  prune_processed
}

# Set at the top level: in zsh, a trap set inside a function fires when that function returns.
# INT and TERM end the run there and then, with the half-written file removed, rather than
# releasing the lock and going on to the next recording.
stop_run() {
  [[ -n "$CURRENT_CHILD" ]] && kill "$CURRENT_CHILD" 2> /dev/null && wait "$CURRENT_CHILD" 2> /dev/null
  [[ -n "$CURRENT_PART" ]] && rm -f "$CURRENT_PART"
  release_lock
  exit "$1"
}
trap release_lock EXIT
trap 'stop_run 130' INT
trap 'stop_run 143' TERM
main "$@"
