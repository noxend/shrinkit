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
# under Homebrew it always answers with the versioned Cellar path whichever route was used to run
# it (measured: through bin/, through opt/, and directly). That path disappears on the next
# `brew upgrade`, silently taking every Finder entry and the agent with it, so it is mapped back to
# brew's own per-formula path, which is documented as surviving upgrades.
self_path() {
  local self="${ZSH_ARGZERO:A}"
  [[ "$self" == */Cellar/shrinkit/*/bin/shrinkit ]] \
    && print -r -- "${self%/Cellar/shrinkit/*}/opt/shrinkit/bin/shrinkit" \
    || print -r -- "$self"
}

# Where presets/ and quick-action/ are read from: beside the script in a checkout, and under
# share/shrinkit in a Homebrew keg. SHRINKIT_REPO still wins when it is set at all, so the test
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

BASE_DIR="${SHRINKIT_DIR:-$HOME/Movies/shrinkit}"
SELF="$(self_path)"
REPO_DIR="$(data_dir)" # where the Quick Action template and the stock presets live
# Installed without a .sh extension so it reads as "shrinkit", not "zsh", in the
# System Settings > Login Items background list.
BIN_DIR="$HOME/.local/bin"

# What this script is called from the outside: the path written into the launchd plist, into every
# Quick Action, and into the Full Disk Access instructions. Read afresh each time one is written,
# since setup makes the link a step before it builds them. A checkout is reached through the link
# setup puts on the PATH, so the name stays "shrinkit" and a git pull needs no reinstall; a keg has
# brew's own bin for that, and setup makes no link, so there self_path answers.
registered_path() {
  local link="$BIN_DIR/shrinkit"
  [[ -L "$link" && "${link:A}" == "$SELF" ]] && {
    print -r -- "$link"
    return
  }
  print -r -- "$SELF"
}

IN_DIR="$BASE_DIR/input"        # the watched folder
DONE_DIR="$BASE_DIR/.processed" # originals end up here after a good encode
LOG_DIR="$BASE_DIR/.logs"
LOG="$LOG_DIR/optimizer.log"
LOCK_DIR="$BASE_DIR/.optimizer.lock"

CONFIG="$BASE_DIR/settings.conf"
# named variations on the config, one file each
PRESET_DIR="$BASE_DIR/presets"

OUT_DIR="$BASE_DIR/output"

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

trim() {
  print -r -- "${${1##[[:space:]]#}%%[[:space:]]#}"
}

# A whole line starting with # is a comment; a # elsewhere is part of the value.
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

# Put one setting back to its default and say so, so a bad value never stops a run.
reject() {
  local key="$1" reason="$2"
  log "ignoring $key='${CFG[$key]}' ($reason), using '${DEFAULTS[$key]}'"
  CFG[$key]="${DEFAULTS[$key]}"
}

validate_config() {
  is_num "${CFG[speed]}" && awk -v s="${CFG[speed]}" 'BEGIN { exit !(s > 0) }' \
    || reject speed "want a number above 0"
  # Capped, so a mistyped value cannot hang the encode.
  is_int "${CFG[fps]}" && ((CFG[fps] <= 240)) || reject fps "want 0-240"
  is_int "${CFG[crf]}" && ((CFG[crf] <= 51)) || reject crf "want 0-51"
  is_int "${CFG[max_height]}" || reject max_height "want a whole number"
  [[ "${CFG[codec]}" == h264 || "${CFG[codec]}" == hevc ]] || reject codec "want h264 or hevc"
  is_bool "${CFG[remove_audio]}" || reject remove_audio "want true or false"
  is_bool "${CFG[keep_original]}" || reject keep_original "want true or false"
  # The digit count is bounded before the value ever reaches zsh arithmetic: a long enough digit
  # string gets silently truncated there rather than rejected, and could slip through a bare
  # <=3650 comparison at the wrong truncated value. Capped well short of where keep_days*86400
  # overflows and wraps the cutoff into the future, which would prune everything in .processed/
  # in one pass, freshly-archived files included.
  [[ "${CFG[keep_days]}" =~ ^[0-9]{1,4}$ ]] && ((CFG[keep_days] <= 3650)) || reject keep_days "want 0-3650"
  is_bool "${CFG[notify]}" || reject notify "want true or false"
  is_bool "${CFG[notify_start]}" || reject notify_start "want true or false"
  is_bool "${CFG[copy_to_clipboard]}" || reject copy_to_clipboard "want true or false"
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

# A stray *.cuts-looking file next to a video whose exact sidecar name is missing is usually a typo
# (dropped extension, Finder tacking on .txt) rather than "no cuts wanted" -- worth a banner, since
# that mistake would otherwise ship the source unredacted with nothing to show for it. Anchored to
# the video's own name, not a bare "starts with the same letters" prefix match: a plain prefix glob
# also caught a second, unrelated recording sharing the first few characters of its name (Finder's
# own "clip.mov" / "clip 2.mov" duplicate naming is the everyday way to hit that), warning about a
# sidecar that was never meant for this video at all.
warn_near_miss_cuts_file() {
  # Split, not one local: zsh expands the whole line before src is local, so "${src:t}" on it would
  # read the caller's src, silently, whenever the caller happens to have one.
  local src="$1" stray
  local expected="${src:t}.cuts"
  local -a strays
  strays=("${src:h}/${src:t:r}.cuts"(N) "${src:h}/${expected}"*(N))
  for stray in "${strays[@]}"; do
    [[ "${stray:t}" == "$expected" ]] && continue
    log "found '${stray:t}' next to ${src:t}, expected '${expected}' -- no cuts applied"
    notify "${src:t}: found '${stray:t}', expected '${expected}' -- no cuts applied"
    return
  done
}

# One "start-end" range to a "start end" pair in seconds, or nothing plus a log line saying why it
# was rejected. where names the range's origin for that log line, since a range reaches here from
# the sidecar file, from --cut or from --keep. kind is "cut" or "keep", and changes only how a
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

# The ranges to cut, from --keep or --cut if any were named there and from <name>.cuts next to
# <name> otherwise. Prints them as sorted, merged "start end" pairs, one per line in seconds, or
# nothing if there is no sidecar file and neither flag, or nothing valid in any of them. A bad
# range is skipped and logged rather than spoiling the ones around it.
read_cuts() {
  # cuts_file on its own line: see warn_near_miss_cuts_file() above.
  local src="$1" duration="$2" line pair
  local cuts_file="${src}.cuts"
  local -a pairs
  # --keep names the footage to survive, so the ranges to cut are what it leaves out: the same
  # pairs, complemented against the real length. Everything downstream of here is the cut path
  # unchanged, since a keep is only ever a cut described from the other side.
  if ((${#KEEP_RANGES} > 0)); then
    [[ -f "$cuts_file" ]] && log "using --keep, ignoring ${cuts_file:t}"
    for line in "${KEEP_RANGES[@]}"; do
      pair="$(parse_range "$line" "$duration" "from --keep" keep)" && pairs+=("$pair")
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
  # --cut replaces the sidecar rather than adding to it, the same way every other flag beats the
  # file it has an equivalent in. Naming ranges on the command line and silently getting the file's
  # as well would be the worse surprise of the two, so the file is ignored out loud instead.
  if ((${#CUT_RANGES} > 0)); then
    [[ -f "$cuts_file" ]] && log "using --cut, ignoring ${cuts_file:t}"
    for line in "${CUT_RANGES[@]}"; do
      pair="$(parse_range "$line" "$duration" "from --cut" cut)" && pairs+=("$pair")
    done
    ((${#pairs} > 0)) && printf '%s\n' "${pairs[@]}" | sort -n -k1,1 | merge_cut_ranges
    return 0
  fi
  if [[ ! -f "$cuts_file" ]]; then
    warn_near_miss_cuts_file "$src"
    return 0
  fi
  if [[ ! -r "$cuts_file" ]]; then
    log "cannot read ${cuts_file:t} (check its permissions); no cuts applied"
    notify "${src:t}: cannot read ${cuts_file:t} (check its permissions), no cuts applied"
    return 1
  fi
  # The `|| [[ -n "$line" ]]` catches a last line with no trailing newline, which read would
  # otherwise drop silently: a single-line .cuts file missing one would apply no cut at all.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "${line%%\#*}")"
    [[ -z "$line" ]] && continue
    pair="$(parse_range "$line" "$duration" "in ${cuts_file:t}" cut)" && pairs+=("$pair")
  done < "$cuts_file"
  # Always 0 past this point, whether or not any line produced a usable range: a bad line already
  # got its own log entry above, and cuts_note() needs a plain 0 to tell "no ranges parsed" apart
  # from the two harder failures above that already notified on their own.
  ((${#pairs} > 0)) && printf '%s\n' "${pairs[@]}" | sort -n -k1,1 | merge_cut_ranges
  return 0
}

# Sorted "start end" pairs in, one per line on stdin; merges any that touch or overlap so two
# ranges from separate .cuts lines can never leave a keep-segment with a negative length.
merge_cut_ranges() {
  awk '
    NR == 1 { s = $1; e = $2; next }
    $1 <= e { if ($2 > e) e = $2; next }
    { print s, e; s = $1; e = $2 }
    END { if (NR > 0) print s, e }
  '
}

# ", cut applied" once at least one range took; ", cut requested but none applied" when a cut was
# asked for, by sidecar, by --cut or by --keep, and every range in it was rejected -- empty
# otherwise (nothing asked for a cut, or read_cuts already notified directly about a harder
# failure, like a sidecar it could not read at all).
cuts_note() {
  local src="$1" cuts="$2" rc="$3" asked=cut
  # 2 is read_cuts() saying every --keep range was good and together they cover the whole clip.
  # Nothing is left to cut, and nothing went wrong, so it must not read like a rejected range.
  [[ "$rc" -eq 2 ]] && {
    print -r -- ", kept the whole clip, nothing to cut"
    return 0
  }
  [[ "$rc" -eq 0 ]] || return 0
  ((${#KEEP_RANGES} > 0)) && asked=keep
  [[ -f "${src}.cuts" ]] || ((${#CUT_RANGES} > 0)) || ((${#KEEP_RANGES} > 0)) || return 0
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
  # with no cuts at all -- otherwise "fps" stops being a cap the moment a .cuts file is involved.
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

  # Written to a hidden temp file first, so two runs on one name can never collide mid-write.
  local part="${out:h}/.${out:t:r}.$$.part.mp4"

  log "encode ${src:t} ($label)"
  "$FFMPEG" -nostdin -y -i "$src" "${filter_args[@]}" \
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
  # ffmpeg writing $part is not proof the folder is actually writable to the process running this:
  # a right-click Quick Action runs as Automator/Finder, which needs its own Full Disk Access grant
  # for Desktop/Documents/Downloads, separate from Terminal's -- and unlike ffmpeg failing loudly,
  # a denied rename here used to fail with no explanation at all, leaving the temp file behind.
  mv -f "$part" "$out" || {
    log "FAILED ${src:t}: could not write ${out:t} (Desktop, Documents and Downloads need Full Disk Access granted to whatever ran this)"
    rm -f "$part"
    return 1
  }
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

  cuts="$(read_cuts "$src" "$(video_duration "$src")")"
  rc=$?
  note="$(cuts_note "$src" "$cuts" "$rc")"

  encode "$src" "$out" "$cuts" || {
    # A watched file is always in input/; a right-clicked one can be anywhere, so name the path.
    [[ "$archive" == true ]] \
      && log "FAILED ${src:t}, left in place (ffmpeg output is above)" \
      || log "FAILED $src (one-shot, ffmpeg output is above)"
    notify "${src:t}" "Could not shrink"
    return 1
  }
  after="$(human_size "$out")"

  if [[ "$archive" == true ]]; then
    if [[ "${CFG[keep_original]}" == true ]]; then
      # touch: mv keeps the file's own mtime, but keep_days counts from when it was archived. The
      # sidecar move is gated on the first mv succeeding, so a locked or permission-denied source
      # cannot leave its .cuts sidecar archived while the video itself stays stuck in input/.
      mv "$src" "$DONE_DIR/" && {
        touch "$DONE_DIR/${src:t}"
        [[ -f "${src}.cuts" ]] && mv "${src}.cuts" "$DONE_DIR/" && touch "$DONE_DIR/${src:t}.cuts"
      }
    else
      rm -f "$src" "${src}.cuts"
    fi
  fi
  announce "${src:t:r}" "$out" "$before" "$after" "$note"
}

# One-shot mode (the Finder Quick Action): write the result next to each source, originals alone.
optimize_files() {
  local src out
  for src in "$@"; do
    [[ -f "$src" ]] || {
      log "skip   $src (not a file)"
      continue
    }
    # The right-click menu only offers video files, but a .cuts sidecar sits right next to its
    # recording and is easy to select along with it -- without this, encode() would be handed a
    # text file and fail with a "could not shrink" notification naming the sidecar, not the video.
    [[ "$src" == (#i)*.(mov|mp4|m4v) ]] || {
      log "skip   ${src:t} (not a video)"
      continue
    }
    out="${src:h}/$(output_name "$src")"
    [[ -e "$out" ]] && out="${src:h}/${${out:t}:r}-$(date +%s).mp4"
    shrink "$src" "$out" false
  done
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
      if [[ -e "$out" ]]; then
        log "skip   ${src:t} (already has an optimized copy)"
      elif ! is_settled "$src"; then
        log "skip   ${src:t} (still being written)"
      elif shrink "$src" "$out" true; then
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

# --------------------------------------------------------------------- the config subcommand

config_show() {
  local key
  for key in "${(@ko)CFG}"; do print -r -- "$key = ${CFG[$key]}"; done
}

# Rewrites the one line in place so the comments around it survive; a setting the file never
# mentioned is appended.
config_set() {
  local key="${(L)${1//-/_}}" value="$2" line tmp found=0
  [[ -n "${DEFAULTS[$key]+known}" ]] || {
    print -u2 -r -- "unknown setting: $1"
    return 1
  }

  tmp="$(mktemp)"
  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line; do
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

config_command() {
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  case "${1-}" in
    "" | show)
      read_config
      config_show
      ;;
    edit)
      config_edit
      ;;
    *)
      [[ -n "${2-}" ]] || {
        print -u2 -r -- "usage: config [show | edit | <setting> <value>]"
        return 2
      }
      config_set "$1" "$2" || return 2
      ;;
  esac
}

# --------------------------------------------------------------------- presets

SERVICES_DIR="$HOME/Library/Services"

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
# it runs and the name it shows replaced. Every entry differs only in those two.
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
  /System/Library/CoreServices/pbs -update 2> /dev/null || true

  print -r -- "right-click a video > shrinkit: $name"
}

install_preset_action() {
  local name="$1"
  [[ -f "$(preset_file "$name")" ]] || {
    print -u2 -r -- "no preset called '$name' (looked in $PRESET_DIR)"
    return 1
  }
  install_quick_action "$name" \
    "SHRINKIT_DIR=\"$BASE_DIR\" \"$(registered_path)\" --preset \"$name\" \"\$@\""
}

remove_preset_action() {
  rm -rf "$SERVICES_DIR/shrinkit: $1.workflow"
  /System/Library/CoreServices/pbs -update 2> /dev/null || true
  print -r -- "removed the Quick Action for '$1'"
}

preset_command() {
  mkdir -p "$PRESET_DIR"
  case "${1-}" in
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
      print -u2 -r -- "usage: preset [install <name>|remove <name>]"
      return 2
      ;;
  esac
}

# A fixed Quick Action, not tied to any preset: it doesn't shrink anything, only opens the sidecar
# (creating it first if needed) so a cut can be marked before a normal preset runs on the file.
install_cuts_action() {
  install_quick_action "mark cuts" \
    "SHRINKIT_DIR=\"$BASE_DIR\" \"$(registered_path)\" mark-cuts \"\$@\""
}

# Seeds a .cuts sidecar with a header comment and the recording's own length, if one is not there
# yet; leaves an existing sidecar's content untouched so a second range can be added to it.
seed_cuts_sidecar() {
  # sidecar on its own line: see warn_near_miss_cuts_file() above.
  local file="$1" dur mins secs
  local sidecar="${file}.cuts"
  [[ -f "$sidecar" ]] && return 0
  dur="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2> /dev/null)"
  {
    print -r -- "# ${file:t}.cuts -- one range per line, e.g. 0:32-0:35 or plain seconds"
    print -r -- "# 0-0:20 cuts the first 20s, 2:30-end cuts from 2:30 to the end"
    if is_num "$dur"; then
      mins=$((${dur%.*} / 60))
      secs=$((${dur%.*} % 60))
      print -r -- "# ${file:t} is ${mins}:$(printf '%02d' "$secs") long"
    fi
  } > "$sidecar"
}

# Finder entry point for authoring a .cuts sidecar: seeds it, then opens both the recording and the
# sidecar so timestamps can be read straight off the player while typing them in.
mark_cuts_command() {
  [[ "${1-}" == --install ]] && {
    install_cuts_action
    return
  }
  (($# > 0)) || {
    print -u2 -r -- "usage: mark-cuts <file>..."
    return 2
  }
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    seed_cuts_sidecar "$file"
    # Player first, sidecar second: the last one opened comes up in front, and the sidecar is the
    # window being typed into. Opened the other way round it hides behind the video and reads as
    # nothing having happened.
    open -- "$file"
    open -e "${file}.cuts"
  done
}

# --------------------------------------------------------------------- merging

# Not tied to a preset, the way mark cuts is not: this entry joins the recordings it is handed
# instead of shrinking any of them.
install_merge_action() {
  install_quick_action merge \
    "SHRINKIT_DIR=\"$BASE_DIR\" \"$(registered_path)\" merge \"\$@\""
}

# When a recording was made, in epoch seconds. Its own creation_time first, which QuickTime writes
# and which survives a rename or a copy, then the filesystem's birth time, then its mtime.
recorded_at() {
  local file="$1" stamp epoch
  stamp="$("$FFPROBE" -v error -show_entries format_tags=creation_time \
    -of default=nw=1:nk=1 "$file" 2> /dev/null | head -1)"
  # Printed as 2026-09-20T09:15:23.000000Z. The fraction and the zone marker are dropped rather
  # than parsed: a second already separates two takes of the same recording.
  if [[ "$stamp" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[T[:space:]]([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    epoch="$(date -j -u -f '%Y-%m-%d %H:%M:%S' "${match[1]} ${match[2]}" +%s 2> /dev/null)"
    is_int "$epoch" && {
      print -r -- "$epoch"
      return
    }
  fi
  epoch="$(stat -f%B "$file" 2> /dev/null)"
  is_int "$epoch" || epoch="$(stat -f%m "$file" 2> /dev/null)"
  is_int "$epoch" && print -r -- "$epoch" || print -r -- 0
}

# Sort key for one clip: "0 <number>" for a name that opens with one, "1 <recorded>" for every name
# that does not, so numbered clips lead and the rest follow in the order they were shot. The number
# has to be followed by a space or be the whole name, since every other separator belongs to a date
# as readily as to a take: "12-01-2026 demo.mov" read as take 12 joins a set backwards, while the
# same name left unnumbered still lands in its recorded place. At most three digits, so a name
# opening with a bare year is a name too.
merge_order_key() {
  local name="${1:t:r}"
  if [[ "$name" =~ ^([0-9]{1,3})([[:space:]]|$) ]]; then
    print -r -- "0 ${match[1]}"
  else
    print -r -- "1 $(recorded_at "$1")"
  fi
}

# The clips' positions, one per line, in the order they are to be joined. Ties keep the order they
# were handed in, which for the right-click entry is the order Finder is showing them in.
merge_order() {
  local -a keyed
  local i
  for ((i = 1; i <= $#; i++)); do
    keyed+=("$(merge_order_key "${@[i]}") $i")
  done
  # The position is sorted, never the path: a file name is free to contain the separator and the
  # newline this is sorted on, and a position is not.
  printf '%s\n' "${keyed[@]}" | sort -n -k1,1 -k2,2 -k3,3 | awk '{ print $3 }'
}

merge_total_duration() {
  local src dur total=0
  for src in "$@"; do
    dur="$(clip_duration "$src")"
    [[ -n "$dur" ]] || return 1
    # zsh's own arithmetic, not awk's: awk formats a float through the locale, so a machine set to
    # a comma decimal separator hands back "24,5" for the next reader to take as 24.
    total=$((total + dur))
  done
  print -r -- "$total"
}

# What has to match for clips to be joined without re-encoding: the codecs, the frame size, the
# pixel format and the audio layout, one line per stream, so a clip with no sound never matches
# one that has some.
merge_signature() {
  "$FFPROBE" -v error \
    -show_entries stream=codec_name,codec_type,width,height,pix_fmt,sample_rate,channels \
    -of csv=p=0 "$1" 2> /dev/null
}

merge_signatures_match() {
  local first src
  first="$(merge_signature "$1")"
  [[ -n "$first" ]] || return 1
  shift
  for src in "$@"; do
    [[ "$(merge_signature "$src")" == "$first" ]] || return 1
  done
}

# The concat demuxer's list file. Absolute paths, so the list itself can live anywhere, and the one
# quoting rule that format has: a single quote inside a path would otherwise end the quoted string.
write_concat_list() {
  local list="$1" src quoted q="'" esc="'\''"
  shift
  : > "$list"
  for src in "$@"; do
    quoted="${${src:A}//$q/$esc}"
    print -r -- "file '$quoted'" >> "$list"
  done
}

# Joins the clips without touching their streams: fast, and the result is exactly the clips' own
# quality. Only safe once merge_signatures_match() says they agree.
merge_copy() {
  local out="$1" list rc
  shift
  list="$(mktemp)"
  write_concat_list "$list" "$@"
  # -map, because ffmpeg's default selection keeps one stream per kind: a screen recording carrying
  # both system sound and a microphone would lose the microphone without a word. The ? makes the
  # audio side optional, so a set of silent takes still copies.
  "$FFMPEG" -nostdin -y -f concat -safe 0 -i "$list" -map 0:v -map '0:a?' -c copy \
    -movflags +faststart "$out" >> "$LOG" 2>&1
  rc=$?
  rm -f "$list"
  return $rc
}

# ffmpeg exits 0 over a copy of streams that differ deeper than a probe can see (each encoder's own
# SPS/PPS, say), leaving a file that plays back short or stalls partway. The joined length against
# the sum of the parts is the sensor that sends such a file to the re-encode path instead of
# shipping it as the merge.
merge_duration_ok() {
  local out="$1" expected="$2" actual
  actual="$(clip_duration "$out")"
  [[ -n "$actual" && -n "$expected" ]] || return 1
  awk -v a="$actual" -v b="$expected" 'BEGIN { exit !(a - b < 0.5 && b - a < 0.5) }'
}

# Joins clips that do not agree: each one scaled into the largest frame in the set and padded to
# keep its own shape, and given a silent track when something else in the set has sound, since
# concat wants the same streams from every segment. crf 18 stays close to the sources on purpose:
# this is the merge step, and shrinking is a separate one that should not be paid for twice.
merge_encode() {
  local out="$1"
  shift
  local -a clips=("$@") inputs chains audio_args
  local src dur width height maxw=0 maxh=0 audio=false labels="" i

  for src in "${clips[@]}"; do
    width="$(video_width "$src")"
    height="$(video_height "$src")"
    ((width > maxw)) && maxw=$width
    ((height > maxh)) && maxh=$height
    has_audio "$src" && audio=true
  done
  # libx264 refuses an odd frame size in yuv420p, and a padded frame is free to be one.
  ((maxw % 2)) && maxw=$((maxw + 1))
  ((maxh % 2)) && maxh=$((maxh + 1))

  for ((i = 1; i <= ${#clips}; i++)); do
    src="${clips[i]}"
    inputs+=(-i "$src")
    chains+=("[$((i - 1)):v]scale=${maxw}:${maxh}:force_original_aspect_ratio=decrease,pad=${maxw}:${maxh}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[v$i]")
    # concat reads one segment's streams together, so a segment's labels stay next to each other:
    # [v1][a1][v2][a2], not every video first.
    labels="${labels}[v$i]"
    [[ "$audio" == true ]] || continue
    if has_audio "$src"; then
      chains+=("[$((i - 1)):a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$i]")
    else
      dur="$(clip_duration "$src")"
      [[ -n "$dur" ]] || {
        log "FAILED merge: cannot read how long ${src:t} is, so it cannot be given a silent track"
        return 1
      }
      chains+=("anullsrc=r=48000:cl=stereo,atrim=duration=${dur},asetpts=PTS-STARTPTS[a$i]")
    fi
    labels="${labels}[a$i]"
  done

  local graph="${(j:;:)chains};${labels}concat=n=${#clips}:v=1"
  local -a maps
  if [[ "$audio" == true ]]; then
    graph="${graph}:a=1[vout][aout]"
    maps=(-map '[vout]' -map '[aout]')
    audio_args=(-c:a aac -b:a 128k)
  else
    graph="${graph}:a=0[vout]"
    maps=(-map '[vout]')
    audio_args=(-an)
  fi

  "$FFMPEG" -nostdin -y "${inputs[@]}" -filter_complex "$graph" "${maps[@]}" \
    "${audio_args[@]}" -c:v libx264 -crf 18 -preset veryfast -pix_fmt yuv420p \
    -movflags +faststart "$out" >> "$LOG" 2>&1
}

# Joins the clips, in the order given, into one file beside the first of them, and prints the path
# it wrote. Non-zero means nothing was written and every source is untouched.
merge_files() {
  local -a clips=("$@")
  local first="${clips[1]}" part out total mode=""

  total="$(merge_total_duration "${clips[@]}")" || total=""
  part="${first:h}/.${first:t:r}-merged.$$.part.${first:e}"

  if ! merge_signatures_match "${clips[@]}"; then
    log "merge  the clips differ in size, codec or sound, so they are re-encoded to match"
  elif ! merge_copy "$part" "${clips[@]}"; then
    rm -f "$part"
    log "merge  joining the streams as they are failed, re-encoding instead (ffmpeg output is above)"
  elif [[ -z "$total" ]]; then
    # Nothing was measured, so nothing is wrong yet: ffmpeg exited 0, and a container that does not
    # state its length is a fact about the source rather than evidence against the copy.
    log "merge  the takes do not state how long they are, so the joined file is kept unchecked"
    mode="streams copied"
  elif ! merge_duration_ok "$part" "$total"; then
    rm -f "$part"
    log "merge  the joined file came out the wrong length, re-encoding instead"
  else
    mode="streams copied"
  fi

  if [[ -z "$mode" ]]; then
    part="${first:h}/.${first:t:r}-merged.$$.part.mp4"
    merge_encode "$part" "${clips[@]}" || {
      rm -f "$part"
      return 1
    }
    mode="re-encoded"
  fi

  out="${first:h}/${first:t:r}-merged.${part:e}"
  [[ -e "$out" ]] && out="${out:r}-$(date +%s).${part:e}"
  # Two merges of the same takes inside one second would otherwise land on that same name, and the
  # mv below overwrites. No other run can hold this pid while this one is still using it.
  [[ -e "$out" ]] && out="${out:r}-$$.${part:e}"
  # The same rename that encode() guards: a Quick Action runs as Finder, which needs its own Full
  # Disk Access grant for Desktop, Documents and Downloads.
  mv -f "$part" "$out" || {
    log "FAILED merge: could not write ${out:t} (Desktop, Documents and Downloads need Full Disk Access granted to whatever ran this)"
    rm -f "$part"
    return 1
  }
  log "merged ${#clips} clips into ${out:t} ($mode)"
  print -r -- "$out"
}

# The size line, clipboard copy and banner for a merge. Kept apart from announce(), which speaks in
# before/after sizes: a merge has nothing to be smaller than.
announce_merge() {
  local out="$1" clips="$2" size="$3" extra=""
  if [[ "${CFG[copy_to_clipboard]}" == true ]]; then
    copy_to_clipboard "$out"
    extra=", copied to clipboard"
  fi
  log "done   ${out:t} ($clips clips, $size)$extra"
  notify "${out:t:r}   $clips clips, $size$extra"
}

# Finder entry point for joining several recordings: one file beside the first clip, the sources
# left where they are. It does not shrink, so the result goes through a preset afterwards like any
# other recording.
merge_command() {
  [[ "${1-}" == --install ]] && {
    install_merge_action
    return
  }

  mkdir -p "$LOG_DIR"
  read_config
  validate_config
  [[ -x "$FFMPEG" ]] || {
    log "ffmpeg is not on PATH or in the Homebrew folders"
    return 1
  }

  local -a clips ordered
  local src i out
  for src in "$@"; do
    [[ -f "$src" ]] || {
      log "skip   $src (not a file)"
      continue
    }
    [[ "$src" == (#i)*.(mov|mp4|m4v) ]] || {
      log "skip   ${src:t} (not a video)"
      continue
    }
    clips+=("$src")
  done
  # One file selected and merge asked for is a slip, not an instruction to copy that file under a
  # new name. A banner as well as stderr, since nothing a Quick Action prints is ever seen.
  ((${#clips} >= 2)) || {
    print -u2 -r -- "merge needs at least two videos, got ${#clips}"
    log "merge needs at least two videos, got ${#clips}"
    notify "merge needs at least two videos"
    return 2
  }

  for i in ${(f)"$(merge_order "${clips[@]}")"}; do ordered+=("${clips[i]}"); done
  log "merge  ${(j:, :)${(@)ordered:t}}"
  notify_start "${#ordered} clips" "Merging…"

  out="$(merge_files "${ordered[@]}")" || {
    log "FAILED merge of ${#ordered} clips (ffmpeg output is above)"
    notify "${ordered[1]:t}" "Could not merge"
    return 1
  }
  announce_merge "$out" "${#ordered}" "$(human_size "$out")"
}

# --------------------------------------------------------------------- run

usage() {
  print -r -- "usage: ${ZSH_ARGZERO:t} [--setting value ...] [file ...]
       ${ZSH_ARGZERO:t} config [show | edit | <setting> <value>]
       ${ZSH_ARGZERO:t} preset [install <name> | remove <name>]
       ${ZSH_ARGZERO:t} mark-cuts <file>...
       ${ZSH_ARGZERO:t} merge <file>...

  no files       optimize everything waiting in $IN_DIR
  file ...       optimize those files where they are, next to each source

Every setting is also a flag, so --crf 24 or --speed 3 changes one run without
touching the config. A true/false setting takes no value: --remove-audio turns
it on, --no-remove-audio turns it off.

--cut takes one range, and repeats for more: --cut 0:32-0:35 --cut 2:30-end.
--keep is the same edit from the other side: it names the footage to survive
and cuts everything else, so --keep 1:00-2:00 leaves exactly that minute.
Use one or the other, not both. Either replaces the .cuts sidecar for that
run rather than adding to it, and either needs the file named, since a
timestamp only means something in one recording.

A preset is a file of the same settings in $PRESET_DIR.
Use one for a run with --preset <name>, or turn it into its own right-click
entry with 'preset install <name>'.

mark-cuts opens (creating first, if needed) the .cuts sidecar for each file
alongside the recording itself, ready to mark a range to cut. Same as the
right-click 'shrinkit: mark cuts' entry.

merge joins several recordings into one, in the order they were recorded, or by
a number at the start of the file name (1 intro.mov, 2 bug.mov) for any that
carry one. The result lands beside the first clip and the originals stay where
they are. It does not shrink: run a preset on the result afterwards. Same as the
right-click 'shrinkit: merge' entry.

  settings       $CONFIG
  presets        $PRESET_DIR
  log            $LOG"
}

# Every setting doubles as a flag, so there is no explicit list of them here.
typeset -A OVERRIDES
typeset -a FILES
typeset -a CUT_RANGES
typeset -a KEEP_RANGES
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
      # Both repeatable, one range each, so several ranges read the same on the command line as
      # they do in a sidecar: one range per flag, one range per line. --keep is the same argument
      # seen from the other side, so it is parsed the same way and told apart only at the end.
      --cut | --keep)
        flag="$arg"
        shift
        # An empty value is refused rather than skipped: it still counts as "ranges were asked
        # for", so letting it through would suppress the recording's own sidecar and then
        # contribute no range to replace it. A wrapper expanding an unset variable is the way this
        # actually happens. Command-line syntax is checked strictly here; the
        # never-abort-on-one-bad-value convention covers settings and sidecar lines, not a
        # malformed invocation.
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
      shift
      mark_cuts_command "$@"
      return
      ;;
    merge)
      shift
      merge_command "$@"
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
  # for it, ignore any sidecar those files carried, and with keep_original = false delete every
  # source and sidecar it just overrode. Every other flag is safe to apply queue-wide; these are not.
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
trap release_lock EXIT INT TERM
main "$@"
