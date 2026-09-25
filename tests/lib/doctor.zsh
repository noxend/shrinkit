# Sourced by tests/run-tests.sh: running doctor against a sandboxed install, and reading its report.

# A sandbox with shrinkit set up in it from this checkout, the state most doctor tests start from.
installed_box() {
  local box
  box="$(scratch)"
  setup_box "$box"
  run_setup "$box" > /dev/null 2>&1
  print -r -- "$box"
}

# A PATH with nothing on it but the system and the folders named, since the machine running the
# tests may have a shrinkit of its own on its PATH, and doctor reports a second install. The
# runner's refusing open and osascript stay in front of the system's.
clean_path() {
  local -a dirs=("$@" "$TMPROOT/refuse-bin" /usr/bin /bin /usr/sbin /sbin)
  print -r -- "${(j.:.)dirs}"
}

# doctor as someone runs it after an install: a new shell, with the folder known from the folder
# file and the plist rather than from SHRINKIT_DIR, and the sandbox's PATH link on the PATH. It
# finds ffmpeg in the sandbox's own folder, so where this machine keeps its ffmpeg does not change
# a verdict. Extra NAME=value words go into its environment.
run_doctor() {
  local box="$1"
  shift
  sandboxed "$box"
  [[ -d "$box/tools" ]] || own_ffmpeg "$box"
  env -u SHRINKIT_DIR HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    PATH="$(clean_path "$box/home/.local/bin")" SHRINKIT_TOOL_DIRS="$box/tools" "$@" \
    zsh "$OPTIMIZER" doctor
}

# The line doctor printed for one check, and that line with everything indented under it.
doctor_line() {
  print -r -- "$1" | grep -E "^(ok|warn|FAIL) +$2 "
}
doctor_block() {
  print -r -- "$1" | awk -v check="$2" '
    /^(ok|warn|FAIL) / { inside = ($2 == check) }
    /^$/ { inside = 0 }
    inside
  '
}
verdict_is() {
  [[ "$(doctor_line "$1" "$2")" == "$3 "* ]]
}

# ffmpeg and ffprobe linked into a folder of the sandbox, for doctor to be pointed at through
# SHRINKIT_TOOL_DIRS: the machine running the tests has them in a Homebrew folder, where no test
# could take them away.
own_ffmpeg() {
  mkdir -p "$1/tools"
  ln -sf "$FFMPEG" "$1/tools/ffmpeg"
  ln -sf "$FFPROBE" "$1/tools/ffprobe"
}

# The agent's run, started by hand on an installed sandbox, with its banners off.
run_agent() {
  local box="$1"
  print -r -- 'notify = false' >> "$box/work/settings.conf"
  HOME="$box/home" SHRINKIT_DIR="$box/work" SHRINKIT_REPO="" zsh "$OPTIMIZER" > /dev/null 2>&1
}

# Every file and folder under a sandbox, with what a write would change. The stub's record of the
# calls it answered is left out: it grows with every question, and is read on its own.
listing() {
  find "$1" ! -name launchctl.log -print0 | xargs -0 stat -f '%N %p %z %Fm' | sort
}
