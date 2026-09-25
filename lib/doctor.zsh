#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- doctor

# Each check reads what the part that can fail reads, and only reads: nothing here creates a folder,
# writes a log line or asks launchd for more than a listing.

# What the check being run has found: per problem its verdict, its one-line finding, and the lines
# under it joined by newlines. DOCTOR_OK is what the check's line says when it found nothing.
typeset -a DOCTOR_VERDICTS DOCTOR_FINDINGS DOCTOR_DETAILS
typeset -i DOCTOR_FAILED=0 DOCTOR_WARNED=0
DOCTOR_OK=""
# This shrinkit as a command to paste: "shrinkit" when that is what the PATH finds, its quoted path
# otherwise, as for a clone run as ./shrinkit.sh with nothing on the PATH.
DOCTOR_SELF=shrinkit

# doctor_found FAIL|warn <finding> [detail ...]. Names read from disk end up in these, so a control
# character in one is shown as ? rather than reaching the terminal.
doctor_found() {
  local -a lines
  DOCTOR_VERDICTS+=("$1")
  shift
  lines=("${@//[[:cntrl:]]/?}")
  DOCTOR_FINDINGS+=("${lines[1]}")
  DOCTOR_DETAILS+=("${(pj:\n:)lines[2,-1]}")
}

# One check's line: ok with DOCTOR_OK when it found nothing, otherwise its first problem of the
# worst kind, with the rest of what it found under it. Plain words and no colour, so the report
# survives being pasted into an issue.
doctor_report() {
  local name="$1" verdict=ok lead i indent
  local -a body
  if ((${DOCTOR_VERDICTS[(Ie)FAIL]})); then
    verdict=FAIL
    DOCTOR_FAILED+=1
  elif ((${#DOCTOR_VERDICTS})); then
    verdict=warn
    DOCTOR_WARNED+=1
  fi
  if [[ "$verdict" == ok ]]; then
    printf '%-6s%-15s%s\n' ok "$name" "${DOCTOR_OK//[[:cntrl:]]/?}"
  else
    lead="${DOCTOR_VERDICTS[(i)$verdict]}"
    body=(${(f)DOCTOR_DETAILS[lead]})
    for ((i = 1; i <= ${#DOCTOR_FINDINGS}; i++)); do
      ((i == lead)) || body+=("${DOCTOR_FINDINGS[i]}" ${(f)DOCTOR_DETAILS[i]})
    done
    printf '%-6s%-15s%s\n' "$verdict" "$name" "${DOCTOR_FINDINGS[lead]}"
    indent="$(printf '%21s' '')"
    ((${#body})) && print -rl -- "${(@)body/#/$indent}"
  fi
  DOCTOR_VERDICTS=() DOCTOR_FINDINGS=() DOCTOR_DETAILS=() DOCTOR_OK=""
}

# A value from the agent's plist.
agent_value() {
  plutil -extract "$1" raw -o - "$PLIST" 2> /dev/null
}

# --------------------------------------------------------------------- the checks

# This install, or the path setup registers for it: for a checkout in Desktop, Documents or
# Downloads that is a copy in ~/.local, which stands for the checkout.
this_install() {
  [[ "${1:A}" == "${ZSH_ARGZERO:A}" || "${1:A}" == "${$(registered_path):A}" ]]
}

# Which shrinkit this is, and whether another one comes first on the PATH or is what the watcher
# runs: two installs split the tool, each way in running a version the other may not be.
doctor_check_command() {
  local kind="a clone" onpath program
  local -a others fixes=("  ${(qq)SELF} setup")
  installed_by_brew && kind=Homebrew
  [[ "$SELF" == "${BIN_DIR:A}/shrinkit" ]] && kind="copied from a clone"
  DOCTOR_OK="$SELF ($kind)"
  onpath="$(whence -p shrinkit)"
  if [[ -n "$onpath" ]] && ! this_install "$onpath"; then
    others+=("'shrinkit' on your PATH is $onpath")
    fixes+=("  ${(qq)onpath} setup")
  fi
  program="$(agent_value ProgramArguments.0)"
  if [[ -n "$program" ]] && ! this_install "$program"; then
    others+=("the watcher runs $program")
    [[ "${program:A}" == "${onpath:A}" ]] || fixes+=("  ${(qq)program} setup")
  fi
  ((${#others})) && doctor_found warn "two installs are in play" \
    "This is $SELF ($kind), while" "${others[@]}" \
    "Run setup from the one to keep; the watcher and the right-click entries follow it:" \
    "${fixes[@]}"
}

# ffmpeg and ffprobe found the way a right-click entry finds them: launchd's PATH and the Homebrew
# folders. The watcher's PATH has those and the folder setup found ffmpeg in, so what passes here
# passes for both. And ffmpeg has to run.
doctor_check_ffmpeg() {
  local base_path=/usr/bin:/bin:/usr/sbin:/sbin ffmpeg ffprobe out rc
  local -a missing
  ffmpeg="$(PATH="$base_path" find_tool ffmpeg)"
  ffprobe="$(PATH="$base_path" find_tool ffprobe)"
  [[ -n "$ffmpeg" ]] || missing+=(ffmpeg)
  [[ -n "$ffprobe" ]] || missing+=(ffprobe)
  if ((${#missing})); then
    doctor_found FAIL "${(j: and :)missing} not found where shrinkit looks" \
      "It looks in ${(j:, :)TOOL_DIRS} and on ${base_path}. The watcher may also find it on" \
      "the PATH setup gave it; the right-click entries do not. Install it with:" \
      "  brew install ffmpeg"
    return
  fi
  DOCTOR_OK="$ffmpeg"
  out="$("$ffmpeg" -version 2>&1 < /dev/null)" || {
    rc=$?
    doctor_found FAIL "$ffmpeg does not run (exit status $rc)" ${out:+"${${(f)out}[1]}"} \
      "Reinstall it with:" \
      "  brew reinstall ffmpeg"
  }
}

# The working folder in effect: there, and writable where a run writes, the folder itself included
# since the lock is taken there. And the folder this shell would use against the watcher's.
doctor_check_folder() {
  local base="$BASE_DIR" agent place
  local -a unwritable
  DOCTOR_OK="$base"
  agent="$(agent_value EnvironmentVariables.SHRINKIT_DIR)"
  [[ -n "${SHRINKIT_DIR-}" && -n "$agent" && "${SHRINKIT_DIR:A}" != "${agent:A}" ]] \
    && doctor_found warn "SHRINKIT_DIR in this shell is $SHRINKIT_DIR, the watcher's folder is $agent" \
      "Anything run from this shell uses the first. Take SHRINKIT_DIR out of your shell's" \
      "startup file, or move everything to the one to keep:" \
      "  $DOCTOR_SELF config folder <path>"
  if [[ ! -d "$base" ]]; then
    if [[ "${base:A}" == /Volumes/* ]]; then
      doctor_found FAIL "$base does not exist" \
        "Connect the drive it is on, or move shrinkit to a folder on this Mac:" \
        "  $DOCTOR_SELF config folder ~/Movies/shrinkit"
    else
      doctor_found FAIL "$base does not exist" \
        "If you moved it, point shrinkit at where it is now:" \
        "  $DOCTOR_SELF config folder <path>" \
        "or make it again where it was:" \
        "  $DOCTOR_SELF setup"
    fi
    return
  fi
  for place in "$base" "$base"/{input,output,.logs}(N/); do
    [[ -w "$place" ]] || unwritable+=("$place")
  done
  ((${#unwritable})) && doctor_found FAIL "cannot write to ${(j:, :)unwritable}" \
    "Give yourself write access:" \
    "  chmod u+w ${(j: :)${(@qq)unwritable}}" \
    "or, on a drive that is read-only, move to a folder on this Mac:" \
    "  $DOCTOR_SELF config folder ~/Movies/shrinkit"
}

# The agent: its plist, the program it runs, whether launchd has it loaded, and how launchd says
# its last run ended. launchctl keeps that as a wait status, an exit code shifted up by eight, and
# keeps the one before while a run is going on.
doctor_check_watcher() {
  local program listing raw session
  local -a again=("Register it again with:" "  $DOCTOR_SELF setup")
  [[ -f "$PLIST" ]] || {
    doctor_found FAIL "not installed: there is no $PLIST" "${again[@]}"
    return
  }
  plutil -lint "$PLIST" > /dev/null 2>&1 || {
    doctor_found FAIL "$PLIST is not a valid plist" "${again[@]}"
    return
  }
  program="$(agent_value ProgramArguments.0)"
  DOCTOR_OK="loaded: $program"
  if [[ ! -e "$program" ]]; then
    doctor_found FAIL "it runs $program, which is not there" "${again[@]}"
  elif [[ ! -x "$program" ]]; then
    doctor_found FAIL "it runs $program, which is not executable" \
      "Make it executable with:" \
      "  chmod +x ${(qq)program}"
  fi
  # launchctl answers for the session it is asked from, and a login over ssh has its own.
  session="$("$LAUNCHCTL" managername 2> /dev/null)"
  [[ "$session" == Aqua ]] || {
    doctor_found warn "cannot tell from this session whether macOS runs it" \
      "launchd calls this session ${session:-nothing}; run doctor in Terminal on the Mac itself."
    return
  }
  listing="$("$LAUNCHCTL" list "$LABEL" 2> /dev/null)" || {
    doctor_found FAIL "installed, but macOS is not running it" \
      "Usually it was switched off in System Settings > General > Login Items &" \
      "Extensions. Switch shrinkit on there, then run:" \
      "  $DOCTOR_SELF setup"
    return
  }
  ((${#DOCTOR_VERDICTS} == 0)) || return
  [[ "$listing" =~ '"PID" = [0-9]+;' ]] && return
  [[ "$listing" =~ '"LastExitStatus" = ([0-9]+);' ]] && raw="${match[1]}"
  if ((raw >> 8 == 78)); then
    doctor_found FAIL "macOS could not start it (exit 78)" \
      "launchd could not open its log files in ${$(agent_value StandardErrorPath):h}: the folder" \
      "is missing, on a drive that is not connected, or where it needs Full Disk Access." \
      "Once that is fixed, run:" \
      "  $DOCTOR_SELF setup"
  elif ((raw >> 8 == 127)); then
    doctor_found FAIL "could not read $program (exit 127)" \
      "It is somewhere macOS keeps the watcher out of, such as Desktop, Documents or" \
      "Downloads. setup copies it out of those; run it from where it is now:" \
      "  $DOCTOR_SELF setup"
  fi
}

# The right-click entries setup built, matched the way teardown matches them: a command that sets
# SHRINKIT_DIR, so an entry of somebody else's with a similar name is never read as one.
our_entries() {
  local action
  for action in "$SERVICES_DIR"/shrinkit:*.workflow(N); do
    grep -q "SHRINKIT_DIR=" "$action/Contents/document.wflow" 2> /dev/null && print -r -- "$action"
  done
}

# What one entry runs: SHRINKIT_DIR=<folder> <program>, then --preset <name>, edit, merge, or what
# an older setup built. The command is split into words the way zsh splits it, so the quoting of an
# older setup reads the same as today's. Sets ENTRY_NAME, ENTRY_FOLDER, ENTRY_PROGRAM,
# ENTRY_COMMAND and ENTRY_PRESET.
read_entry() {
  local -a words
  words=(${(Q)${(z)"$(plutil -extract actions.0.action.ActionParameters.COMMAND_STRING raw -o - \
    "$1/Contents/document.wflow" 2> /dev/null)"}})
  ENTRY_NAME="${${1:t:r}#shrinkit: }"
  [[ "${words[1]-}" == SHRINKIT_DIR=* ]] || return 1
  ENTRY_FOLDER="${words[1]#SHRINKIT_DIR=}" ENTRY_PROGRAM="${words[2]-}" ENTRY_COMMAND="${words[3]-}"
  ENTRY_PRESET=""
  if [[ "$ENTRY_COMMAND" == --preset ]]; then
    ENTRY_PRESET="${words[4]-}"
  fi
}

# One entry per preset in the working folder, plus edit and merge, each running a program and,
# for a preset's entry, a preset that is there. Whether an entry is switched on in System Settings
# is kept where no command reads it.
doctor_check_right_click() {
  local entry preset name program
  local -a present expected
  local -aU programs
  for preset in "$PRESET_DIR"/*.conf(N.); do
    in_menu "${preset:t:r}" && expected+=("${preset:t:r}")
  done
  expected+=(edit merge)
  for entry in ${(f)"$(our_entries)"}; do
    read_entry "$entry" || continue
    # Anything else was built by an older shrinkit, such as 3.x's mark cuts; setup sweeps it away.
    [[ "$ENTRY_COMMAND" == (--preset|edit|merge) ]] || {
      doctor_found warn "right-click $ENTRY_NAME is left from an older shrinkit" \
        "Build the entries again with:" \
        "  $DOCTOR_SELF setup"
      continue
    }
    present+=("$ENTRY_NAME")
    programs+=("$ENTRY_PROGRAM")
    [[ -z "$ENTRY_PRESET" || -f "$ENTRY_FOLDER/presets/$ENTRY_PRESET.conf" ]] \
      || doctor_found FAIL "right-click $ENTRY_NAME runs the preset $ENTRY_PRESET, which is not in $ENTRY_FOLDER/presets" \
        "Put it back, or build the entries again from the presets there are:" \
        "  $DOCTOR_SELF setup"
  done
  for program in "${programs[@]}"; do
    if [[ ! -e "$program" ]]; then
      doctor_found FAIL "the entries run $program, which is not there" "Build them again with:" "  $DOCTOR_SELF setup"
    elif [[ ! -x "$program" ]]; then
      doctor_found FAIL "the entries run $program, which is not executable" \
        "Make it executable with:" \
        "  chmod +x ${(qq)program}"
    fi
  done
  # The edit entry opens its Terminal window on the launcher setup writes beside the folder file.
  if [[ ! -f "$EDIT_LAUNCHER" ]]; then
    doctor_found FAIL "right-click edit cannot open its window: there is no $EDIT_LAUNCHER" \
      "Write it again with:" "  $DOCTOR_SELF setup"
  elif [[ ! -x "$EDIT_LAUNCHER" ]]; then
    doctor_found FAIL "right-click edit cannot open its window: $EDIT_LAUNCHER is not executable" \
      "Write it again with:" "  $DOCTOR_SELF setup"
  fi
  for name in "${expected[@]}"; do
    ((${present[(Ie)$name]})) && continue
    if [[ "$name" == (edit|merge) ]]; then
      doctor_found warn "no right-click entry for $name" "Build it again with:" "  $DOCTOR_SELF setup"
    else
      doctor_found warn "no right-click entry for the preset $name" "Add it with:" \
        "  $DOCTOR_SELF preset install ${(qq)name}"
    fi
  done
  DOCTOR_OK="${#present} entries (whether each is switched on, doctor cannot see)"
}

# What a run would log about one settings file read on its own: every line it leaves out, and
# every value it puts back to the default. Read through the functions a run uses, with the log sent
# here rather than to the file, so doctor reports the log's own words.
settings_warnings() {
  local file="$1" label="$2" line
  for line in ${(f)"$( (
    LOG=/dev/stdout
    CFG=("${(@kv)DEFAULTS}")
    read_settings "$file"
    validate_config
  ) 2> /dev/null)"}; do
    line="${${line#????-??-?? ??:??:??  }%, using *}"
    [[ "$line" == *"${file:t}"* ]] || line="$line, in $label"
    doctor_found warn "$line"
  done
}

doctor_check_settings() {
  DOCTOR_OK="$CONFIG"
  if [[ ! -e "$CONFIG" ]]; then
    DOCTOR_OK="no settings.conf, so the defaults are in effect"
  elif [[ ! -r "$CONFIG" ]]; then
    doctor_found warn "cannot read $CONFIG, so a run uses none of it" \
      "Give yourself read access:" \
      "  chmod u+r ${(qq)CONFIG}"
  else
    settings_warnings "$CONFIG" settings.conf
  fi
}

doctor_check_presets() {
  local preset
  local -a names
  for preset in "$PRESET_DIR"/*.conf(N.); do
    names+=("${preset:t:r}")
    settings_warnings "$preset" "presets/${preset:t}"
  done
  DOCTOR_OK="${${(j:, :)names}:-none}"
}

# What is sitting in input/ and why it is still there. The watcher takes plain .mov, .mp4 and .m4v
# files straight inside input/ that are not hidden; a run writes down the ones it shrank but could
# not file away and the ones it could not shrink.
doctor_check_input() {
  local item name
  local -a waiting ignored
  if [[ ! -d "$IN_DIR" ]]; then
    doctor_found warn "there is no $IN_DIR" "Make it again with:" "  $DOCTOR_SELF setup"
    return
  elif [[ ! -r "$IN_DIR" || ! -x "$IN_DIR" ]]; then
    doctor_found warn "cannot look inside $IN_DIR" "Give yourself access:" "  chmod u+rx ${(qq)IN_DIR}"
    return
  fi
  for item in "$IN_DIR"/*(DN); do
    name="${item:t}"
    if [[ "$name" == .DS_Store || "$name" == ._* ]]; then
      continue
    elif [[ "$name" == .* || -L "$item" || ! -f "$item" || "$name" != (#i)*.(mov|mp4|m4v) ]]; then
      [[ -d "$item" ]] && name+=/
      ignored+=("$name")
    elif already_done "$item"; then
      doctor_found warn "$name was shrunk, but could not be moved out of input/" \
        "Its result is in output/, and why it stayed is in:" \
        "  $LOG" \
        "Move it out of input/ yourself."
    elif failed_before "$item"; then
      doctor_found warn "$name could not be shrunk, and is tried again with every drop" \
        "Why is in:" \
        "  $LOG" \
        "Take it out of input/ once you have read it."
    else
      waiting+=("$name")
    fi
  done
  ((${#ignored})) && doctor_found warn "never picked up: ${(j:, :)ignored}" \
    "The watcher takes .mov, .mp4 and .m4v files straight inside input/ and skips hidden ones;" \
    "convert or move these, or take them out."
  DOCTOR_OK="nothing waiting"
  ((${#waiting})) && DOCTOR_OK="${#waiting} waiting: ${(j:, :)waiting}"
}

# --------------------------------------------------------------------- the command

doctor_command() {
  local check
  local -a counts
  (($# == 0)) || {
    print -u2 -r -- "usage: doctor (it takes no arguments)"
    return 2
  }
  this_install "$(whence -p shrinkit)" || DOCTOR_SELF="${(qq)SELF}"
  for check in command ffmpeg folder watcher right-click settings presets input; do
    doctor_check_${check//-/_}
    doctor_report "$check"
  done
  ((DOCTOR_FAILED)) && counts+=("$DOCTOR_FAILED problem${${DOCTOR_FAILED:#1}:+s}")
  ((DOCTOR_WARNED)) && counts+=("$DOCTOR_WARNED warning${${DOCTOR_WARNED:#1}:+s}")
  print -r -- ""
  ((${#counts})) && print -r -- "${(j:, :)counts}." || print -r -- "No problems found."
  ((DOCTOR_FAILED == 0))
}
