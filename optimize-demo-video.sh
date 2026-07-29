#!/bin/zsh
# Optimizes screen recordings dropped into the input folder: speeds them up, strips (or speeds up)
# audio, and re-encodes to a small, universally-playable mp4. All settings live in settings.jsonc in
# the base folder, so there is no need to edit this script. Triggered by a launchd WatchPaths agent,
# and safe to run by hand. Processes everything pending, then exits.

set -u

# Base folder is chosen at install time (DEMO_OPTIMIZER_DIR); defaults to ~/Movies.
BASE_DIR="${DEMO_OPTIMIZER_DIR:-$HOME/Movies/demo-recordings}"
IN_DIR="$BASE_DIR/input"          # drop raw recordings here (this is what the agent watches)
DONE_DIR="$BASE_DIR/.processed"   # originals move here after a successful encode (hidden)
LOG_DIR="$BASE_DIR/.logs"         # all logs live here (hidden)
CONF_JSON="$BASE_DIR/settings.jsonc"
CONF_TXT="$BASE_DIR/settings.txt"   # legacy KEY=value config, still read if present
LOG="$LOG_DIR/optimizer.log"
LOCK_DIR="$BASE_DIR/.optimizer.lock"

# Prefer whatever ffmpeg is on PATH; fall back to the common Homebrew locations.
FFMPEG="$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)"
FFPROBE="$(command -v ffprobe 2>/dev/null || echo /opt/homebrew/bin/ffprobe)"
[[ -x "$FFMPEG" ]] || FFMPEG=/usr/local/bin/ffmpeg
[[ -x "$FFPROBE" ]] || FFPROBE=/usr/local/bin/ffprobe

# --- defaults (used when settings.jsonc is missing or a value is invalid) ---
SPEED=2
FPS=30              # cap the frame rate; 0 keeps the original
CRF=28              # quality/size: lower = bigger and sharper, higher = smaller
CODEC=h264
REMOVE_AUDIO=true
MAX_HEIGHT=0
OUTPUT_SUFFIX=-2x
KEEP_ORIGINAL=true
NOTIFY=true                   # post a macOS banner when a file is done
NOTIFY_TITLE="Video optimized"  # banner title text
NOTIFY_SOUND=Glass            # banner sound (Glass, Ping, Pop, Hero, Submarine, Tink, ...) or none
COPY_TO_CLIPBOARD=false # put the finished file on the clipboard, ready to paste into Slack/Jira/Finder
OUTPUT_DIR=          # empty = <base>/output; or an absolute path to send results elsewhere

mkdir -p "$IN_DIR" "$DONE_DIR" "$LOG_DIR"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >>"$LOG"; }

# Post a Notification Center banner (best effort; never fails the run). The icon is fixed by macOS
# to Script Editor's and cannot be changed here; title and sound are configurable.
notify() {
  [[ "$NOTIFY" == true ]] || return 0
  local msg="${1//\"/}" title="${2:-$NOTIFY_TITLE}"
  title="${title//\"/}"
  local snd=""
  [[ -n "$NOTIFY_SOUND" && "$NOTIFY_SOUND" != (none|off|silent|no) ]] && snd=" sound name \"${NOTIFY_SOUND//\"/}\""
  osascript -e "display notification \"$msg\" with title \"$title\"$snd" >/dev/null 2>&1 || true
}

# Put a file on the clipboard as a file reference (paste it into Finder, Slack, Mail, ...). Uses
# NSPasteboard directly, so it needs no app-control permission. Path passed as argv to avoid quoting.
copy_to_clipboard() {
  osascript -l JavaScript -e 'function run(a){ObjC.import("AppKit");const p=$.NSPasteboard.generalPasteboard;p.clearContents;p.writeObjects($.NSArray.arrayWithObject($.NSURL.fileURLWithPath(a[0])));}' "$1" >/dev/null 2>&1 || true
}

# Ingest KEY=value lines (from JSON or the legacy txt) into the settings, ignoring unknown keys.
apply_settings() {
  while IFS='=' read -r key val; do
    key="${key## }"; key="${key%% }"
    [[ -z "$key" || "$key" == \#* ]] && continue
    val="${val%%\#*}"; val="${val## }"; val="${val%% }"; val="${val//\"/}"
    case "$key" in
      SPEED|FPS|CRF|CODEC|REMOVE_AUDIO|MAX_HEIGHT|OUTPUT_SUFFIX|KEEP_ORIGINAL|NOTIFY|NOTIFY_TITLE|NOTIFY_SOUND|COPY_TO_CLIPBOARD|OUTPUT_DIR) eval "$key=\$val" ;;
    esac
  done
}

# Parse settings.jsonc (JSON with // and /* */ comments) into KEY=value using the built-in
# JavaScriptCore, so there is no extra dependency. Prints PARSE_ERROR if the JSON is invalid.
read_jsonc() {
  osascript -l JavaScript -e 'function run(a){const d=$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null);let s=ObjC.unwrap(d)||"";s=s.replace(/\/\*[\s\S]*?\*\//g,"").replace(/(^|[\s,{])\/\/.*$/gm,"$1");try{const o=JSON.parse(s);return Object.keys(o).map(function(k){return k.toUpperCase()+"="+o[k]}).join("\n");}catch(e){return "PARSE_ERROR";}}' "$1"
}

# --- read settings: prefer settings.jsonc, fall back to the legacy settings.txt ---
if [[ -f "$CONF_JSON" ]]; then
  kv="$(read_jsonc "$CONF_JSON")"
  if [[ "$kv" == "PARSE_ERROR" ]]; then
    log "settings.jsonc is not valid JSON, using defaults for this run"
  else
    print -r -- "$kv" | apply_settings
  fi
elif [[ -f "$CONF_TXT" ]]; then
  apply_settings < "$CONF_TXT"
fi

# --- validate, falling back to defaults so a typo never breaks a run ---
[[ "$SPEED" == <->(.<->)# || "$SPEED" == <-> ]] || { log "bad SPEED '$SPEED', using 2"; SPEED=2; }
awk -v s="$SPEED" 'BEGIN{exit !(s>0)}' || { log "SPEED must be > 0, using 2"; SPEED=2; }
[[ "$FPS" == <-> ]] || { log "bad FPS '$FPS', using 30"; FPS=30; }
[[ "$CRF" == <-> ]] && (( CRF <= 51 )) || { log "bad CRF '$CRF' (0-51), using 28"; CRF=28; }
[[ "$CODEC" == (h264|hevc) ]] || { log "bad CODEC '$CODEC', using h264"; CODEC=h264; }
[[ "$REMOVE_AUDIO" == (true|false) ]] || REMOVE_AUDIO=true
[[ "$MAX_HEIGHT" == <-> ]] || MAX_HEIGHT=0
[[ -n "$OUTPUT_SUFFIX" ]] || OUTPUT_SUFFIX=-2x
[[ "$KEEP_ORIGINAL" == (true|false) ]] || KEEP_ORIGINAL=true
[[ "$NOTIFY" == (true|false) ]] || NOTIFY=true
[[ -n "$NOTIFY_TITLE" ]] || NOTIFY_TITLE="Video optimized"
[[ "$COPY_TO_CLIPBOARD" == (true|false) ]] || COPY_TO_CLIPBOARD=false

# Where results go: a custom absolute path from settings, else <base>/output.
OUT_DIR="$BASE_DIR/output"
if [[ -n "$OUTPUT_DIR" ]]; then
  if [[ "$OUTPUT_DIR" == (/*|\~/*) ]]; then OUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
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

# atempo only handles 0.5..2.0 per stage, so chain stages for larger factors.
atempo_chain() {
  awk -v s="$1" 'BEGIN{
    while (s > 2.0) { printf "atempo=2.0,"; s /= 2.0 }
    while (s < 0.5) { printf "atempo=0.5,"; s /= 0.5 }
    printf "atempo=%.4f", s
  }'
}

setopt local_options null_glob
saw_any=0

# Drain the input folder to empty. Re-scanning after each success means a file dropped WHILE another
# is encoding is picked up by this same run, instead of waiting for launchd to fire again (its
# WatchPaths events get coalesced during a run). A pass that makes no progress ends the loop, so a
# still-writing or failing file cannot spin forever.
while true; do
  made_progress=0
  for src in "$IN_DIR"/*.mov "$IN_DIR"/*.mp4 "$IN_DIR"/*.m4v "$IN_DIR"/*.MOV "$IN_DIR"/*.MP4 "$IN_DIR"/*.M4V; do
    [[ -f "$src" ]] || continue
    saw_any=1
    base="${src:t:r}"
    out="$OUT_DIR/${base}${OUTPUT_SUFFIX}.mp4"

    [[ -e "$out" ]] && { log "skip $src (output already exists)"; continue; }
    is_settled "$src" || { log "skip $src (still being written, will retry on the next event)"; continue; }

    height=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$src" 2>/dev/null | head -1)
    [[ "$height" == <-> ]] || height=1080

    # video filters: speed change, optional downscale, optional frame-rate cap
    vf="setpts=PTS/${SPEED}"
    eff_height="$height"
    if (( MAX_HEIGHT > 0 && height > MAX_HEIGHT )); then
      vf="scale=-2:${MAX_HEIGHT},${vf}"
      eff_height="$MAX_HEIGHT"
    fi
    (( FPS > 0 )) && vf="${vf},fps=${FPS}"

    # Quality-based software encoding (CRF): far smaller than a fixed bitrate for screen recordings.
    if [[ "$CODEC" == hevc ]]; then venc=(-c:v libx265 -crf "$CRF" -preset veryfast -tag:v hvc1)
    else venc=(-c:v libx264 -crf "$CRF" -preset veryfast); fi

    # audio: drop it, or keep and match the new speed (only if the source actually has audio)
    if [[ "$REMOVE_AUDIO" == true ]]; then
      aud=(-an)
    else
      has_audio=$("$FFPROBE" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null | head -1)
      if [[ -n "$has_audio" ]]; then aud=(-c:a aac -b:a 128k -filter:a "$(atempo_chain "$SPEED")"); else aud=(-an); fi
    fi

    log "encode $src  (${height}p${eff_height:+ -> ${eff_height}p}, ${SPEED}x, ${FPS}fps, $CODEC crf${CRF}, audio=$([[ $REMOVE_AUDIO == true ]] && echo off || echo on))"
    if "$FFMPEG" -nostdin -y -i "$src" -filter:v "$vf" "${aud[@]}" "${venc[@]}" -pix_fmt yuv420p -movflags +faststart "$out" >>"$LOG" 2>&1; then
      newsize=$(du -h "$out" | cut -f1 | tr -d ' '); oldsize=$(du -h "$src" | cut -f1 | tr -d ' ')
      if [[ "$KEEP_ORIGINAL" == true ]]; then mv "$src" "$DONE_DIR/"; note="original moved to processed/"; else rm -f "$src"; note="original deleted"; fi
      clip=""
      if [[ "$COPY_TO_CLIPBOARD" == true ]]; then copy_to_clipboard "$out"; clip=", copied to clipboard"; fi
      log "done   $out  (${oldsize} -> ${newsize}); ${note}${clip}"
      notify "${base}   ${oldsize} -> ${newsize}${clip}"
      made_progress=1
    else
      rm -f "$out"
      log "FAILED $src (left in place, see ffmpeg output above)"
      notify "$base" "Optimize failed"
    fi
  done
  (( made_progress )) || break
done

(( saw_any )) || log "no new recordings"
