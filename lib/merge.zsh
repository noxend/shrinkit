#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- merging

# Not tied to a preset: this entry joins the recordings it is handed instead of shrinking any of
# them.
install_merge_action() {
  install_quick_action merge \
    "SHRINKIT_DIR=${(qq)BASE_DIR} ${(qq)$(registered_path)} merge \"\$@\""
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
  run_ffmpeg -nostdin -y -f concat -safe 0 -i "$list" -map 0:v -map '0:a?' -c copy \
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

  run_ffmpeg -nostdin -y "${inputs[@]}" -filter_complex "$graph" "${maps[@]}" \
    "${audio_args[@]}" -c:v libx264 -crf 18 -preset veryfast -pix_fmt yuv420p \
    -movflags +faststart "$out" >> "$LOG" 2>&1
}

# Joins the clips, in the order given, into one file beside the first of them, and prints the path
# it wrote. Non-zero means nothing was written and every source is untouched.
merge_files() {
  local -a clips=("$@")
  local first="${clips[1]}" part out total mode=""

  total="$(merge_total_duration "${clips[@]}")" || total=""
  part="$(temp_part "${first:h}" "${first:t:r}-merged" "${first:e}")"
  CURRENT_PART="$part"

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
    part="$(temp_part "${first:h}" "${first:t:r}-merged" mp4)"
    CURRENT_PART="$part"
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
  mv -f "$part" "$out" 2>> "$LOG" || {
    log "FAILED merge: could not move ${out:t} into ${out:h} (the reason is on the line above)"
    rm -f "$part"
    return 1
  }
  CURRENT_PART=""
  log "merged ${#clips} clips into ${out:t} ($mode)"
  MERGED_OUT="$out"
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

  # Called directly, not in $(...): the part it writes is recorded in CURRENT_PART, and a subshell's
  # copy of that is out of reach of the INT and TERM trap.
  merge_files "${ordered[@]}" || {
    log "FAILED merge of ${#ordered} clips (ffmpeg output is above)"
    notify "${ordered[1]:t}" "Could not merge"
    return 1
  }
  out="$MERGED_OUT"
  announce_merge "$out" "${#ordered}" "$(human_size "$out")"
}
