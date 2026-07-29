#!/bin/zsh
# Optimizes screen recordings dropped into the input folder: speeds them up, strips (or speeds up)
# audio, and re-encodes to a small, universally-playable mp4. All settings live in settings.txt in
# the base folder, so there is no need to edit this script. Triggered by a launchd WatchPaths agent,
# and safe to run by hand. Processes everything pending, then exits.

set -u

# Base folder is chosen at install time (DEMO_OPTIMIZER_DIR); defaults to ~/Movies.
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"
IN_DIR="$BASE_DIR/input"        # drop raw recordings here (this is what the agent watches)
DONE_DIR="$BASE_DIR/processed"  # originals move here after a successful encode
LOG_DIR="$BASE_DIR/logs"        # all logs live here
CONF="$BASE_DIR/settings.txt"
LOG="$LOG_DIR/optimizer.log"
LOCK_DIR="$BASE_DIR/.optimizer.lock"

# Prefer whatever ffmpeg is on PATH; fall back to the common Homebrew locations.
FFMPEG="$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)"
FFPROBE="$(command -v ffprobe 2>/dev/null || echo /opt/homebrew/bin/ffprobe)"
[[ -x "$FFMPEG" ]] || FFMPEG=/usr/local/bin/ffmpeg
[[ -x "$FFPROBE" ]] || FFPROBE=/usr/local/bin/ffprobe

# --- defaults (used when settings.txt is missing or a value is invalid) ---
SPEED=2
REMOVE_AUDIO=true
CODEC=h264
BITRATE=auto
MAX_HEIGHT=0
OUTPUT_SUFFIX=-2x
KEEP_ORIGINAL=true
OUTPUT_DIR=          # empty = <base>/output; or an absolute path to send results elsewhere

mkdir -p "$IN_DIR" "$DONE_DIR" "$LOG_DIR"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >>"$LOG"; }

# --- read settings.txt: KEY=value lines, comments and unknown keys ignored ---
if [[ -f "$CONF" ]]; then
  while IFS='=' read -r key val; do
    key="${key## }"; key="${key%% }"
    [[ -z "$key" || "$key" == \#* ]] && continue
    val="${val%%\#*}"; val="${val## }"; val="${val%% }"; val="${val//\"/}"
    case "$key" in
      SPEED|REMOVE_AUDIO|CODEC|BITRATE|MAX_HEIGHT|OUTPUT_SUFFIX|KEEP_ORIGINAL|OUTPUT_DIR) eval "$key=\$val" ;;
    esac
  done < "$CONF"
fi

# --- validate, falling back to defaults so a typo never breaks a run ---
[[ "$SPEED" == <->(.<->)# || "$SPEED" == <-> ]] || { log "bad SPEED '$SPEED', using 2"; SPEED=2; }
awk -v s="$SPEED" 'BEGIN{exit !(s>0)}' || { log "SPEED must be > 0, using 2"; SPEED=2; }
[[ "$REMOVE_AUDIO" == (true|false) ]] || REMOVE_AUDIO=true
[[ "$CODEC" == (h264|hevc) ]] || { log "bad CODEC '$CODEC', using h264"; CODEC=h264; }
[[ "$BITRATE" == auto || "$BITRATE" == <->k ]] || { log "bad BITRATE '$BITRATE', using auto"; BITRATE=auto; }
[[ "$MAX_HEIGHT" == <-> ]] || MAX_HEIGHT=0
[[ -n "$OUTPUT_SUFFIX" ]] || OUTPUT_SUFFIX=-2x
[[ "$KEEP_ORIGINAL" == (true|false) ]] || KEEP_ORIGINAL=true

# Where results go: a custom absolute path from settings, else <base>/output.
OUT_DIR="$BASE_DIR/output"
if [[ -n "$OUTPUT_DIR" ]]; then
  if [[ "$OUTPUT_DIR" == /* ]]; then OUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
  else log "OUTPUT_DIR must be an absolute path (got '$OUTPUT_DIR'), using default"; fi
fi
mkdir -p "$OUT_DIR" 2>/dev/null || { log "cannot create OUTPUT_DIR '$OUT_DIR', using default"; OUT_DIR="$BASE_DIR/output"; mkdir -p "$OUT_DIR"; }

# --- one run at a time: launchd can fire several events in a row. mkdir is atomic on macOS, so it
# doubles as a lock; a lock left by a killed run is stolen once it is older than 30 min. ---
if [[ -d "$LOCK_DIR" ]]; then
  if [[ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
    log "another run holds the lock, exiting"; exit 0
  fi
  rmdir "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || { log "lost the race for the lock, exiting"; exit 0; }
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

[[ -x "$FFMPEG" ]] || { log "ffmpeg not found (looked on PATH and Homebrew paths)"; exit 1; }

# A recorder writes the file gradually; only touch it once its size has stopped growing.
is_settled() {
  local f="$1" s1 s2
  s1=$(stat -f%z "$f" 2>/dev/null) || return 1
  sleep 2
  s2=$(stat -f%z "$f" 2>/dev/null) || return 1
  [[ "$s1" == "$s2" && "$s1" -gt 0 ]]
}

# Target bitrate by height when BITRATE=auto.
target_bitrate() {
  local h="$1"
  if   (( h <= 720 ));  then echo 3000k
  elif (( h <= 1080 )); then echo 5000k
  elif (( h <= 1440 )); then echo 8000k
  else echo 12000k
  fi
}

# atempo only handles 0.5..2.0 per stage, so chain stages for larger factors.
atempo_chain() {
  awk -v s="$1" 'BEGIN{
    while (s > 2.0) { printf "atempo=2.0,"; s /= 2.0 }
    while (s < 0.5) { printf "atempo=0.5,"; s /= 0.5 }
    printf "atempo=%.4f", s
  }'
}

setopt local_options null_glob
found_any=0

for src in "$IN_DIR"/*.mov "$IN_DIR"/*.mp4 "$IN_DIR"/*.m4v "$IN_DIR"/*.MOV "$IN_DIR"/*.MP4 "$IN_DIR"/*.M4V; do
  [[ -f "$src" ]] || continue
  found_any=1
  base="${src:t:r}"
  out="$OUT_DIR/${base}${OUTPUT_SUFFIX}.mp4"

  [[ -e "$out" ]] && { log "skip $src (output already exists)"; continue; }
  is_settled "$src" || { log "skip $src (still being written, will retry on the next event)"; continue; }

  height=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$src" 2>/dev/null | head -1)
  [[ "$height" == <-> ]] || height=1080

  # video filter: speed change, plus optional downscale
  vf="setpts=PTS/${SPEED}"
  eff_height="$height"
  if (( MAX_HEIGHT > 0 && height > MAX_HEIGHT )); then
    vf="scale=-2:${MAX_HEIGHT},${vf}"
    eff_height="$MAX_HEIGHT"
  fi

  if [[ "$BITRATE" == auto ]]; then br=$(target_bitrate "$eff_height"); else br="$BITRATE"; fi

  if [[ "$CODEC" == hevc ]]; then venc=(-c:v hevc_videotoolbox -tag:v hvc1); else venc=(-c:v h264_videotoolbox -tag:v avc1); fi

  # audio: drop it, or keep and match the new speed (only if the source actually has audio)
  if [[ "$REMOVE_AUDIO" == true ]]; then
    aud=(-an)
  else
    has_audio=$("$FFPROBE" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null | head -1)
    if [[ -n "$has_audio" ]]; then aud=(-c:a aac -b:a 128k -filter:a "$(atempo_chain "$SPEED")"); else aud=(-an); fi
  fi

  log "encode $src  (${height}p${eff_height:+ -> ${eff_height}p}, ${SPEED}x, $CODEC $br, audio=$([[ $REMOVE_AUDIO == true ]] && echo off || echo on))"
  if "$FFMPEG" -nostdin -y -i "$src" -filter:v "$vf" "${aud[@]}" "${venc[@]}" -b:v "$br" -movflags +faststart "$out" >>"$LOG" 2>&1; then
    if [[ "$KEEP_ORIGINAL" == true ]]; then mv "$src" "$DONE_DIR/"; note="original moved to processed/"; else rm -f "$src"; note="original deleted"; fi
    log "done   $out  ($(du -h "$out" | cut -f1)); $note"
  else
    rm -f "$out"
    log "FAILED $src (left in place, see ffmpeg output above)"
  fi
done

(( found_any )) || log "no new recordings"
