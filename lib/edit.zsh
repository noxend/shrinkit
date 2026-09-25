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
}
