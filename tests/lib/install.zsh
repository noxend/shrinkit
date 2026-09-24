# Sourced by tests/run-tests.sh: the sandboxed HOME and launchctl stub that setup and teardown run against.

# --------------------------------------------------------------------- setup and teardown

# A sandboxed HOME, a Desktop to put the shortcut on, and a launchctl that records what it was
# asked for instead of doing it. The real one needs an Aqua session CI does not have, and on a
# developer's machine a test would boot out the agent they are actually using.
setup_box() {
  local box="$1"
  sandboxed "$box"
  mkdir -p "$box/home/Desktop" "$box/stub"
  # Records what it was asked for, and answers bootout the way launchd does: non-zero when the
  # service was never loaded. teardown reads that status to tell "there was no agent" from "there
  # was one and it is gone", so a stub that always succeeded would hide the difference. A test that
  # writes $box/refuse makes bootstrap fail the way launchd refuses a service.
  # list answers as launchctl does on macOS 26: 113 for a service that is not loaded, otherwise the
  # program of the plist it was bootstrapped with, the last exit status from $box/last-exit, which a
  # test writes the way launchd keeps it (a wait status: exit 78 is 78 << 8), and a PID from
  # $box/pid while a run is going on. managername answers Aqua, or what $box/session says.
  cat > "$box/stub/launchctl" << STUB
#!/bin/zsh
print -r -- "\$@" >> "$box/launchctl.log"
case "\$1" in
  bootstrap)
    [[ -f "$box/refuse" ]] && {
      print -u2 -r -- "Bootstrap failed: 5: Input/output error"
      exit 5
    }
    plutil -extract ProgramArguments.0 raw -o - "\$3" > "$box/loaded"
    ;;
  bootout)
    [[ -f "$box/loaded" ]] || exit 3
    rm -f "$box/loaded"
    ;;
  list)
    [[ -f "$box/loaded" ]] || {
      print -u2 -r -- "Could not find service \"\$2\" in domain for port"
      exit 113
    }
    printf '{\n\t"LimitLoadToSessionType" = "Aqua";\n\t"Label" = "%s";\n\t"OnDemand" = true;\n\t"LastExitStatus" = %s;\n' \
      "\$2" "\$(cat "$box/last-exit" 2> /dev/null || print 0)"
    [[ -f "$box/pid" ]] && printf '\t"PID" = %s;\n' "\$(< "$box/pid")"
    printf '\t"Program" = "%s";\n\t"ProgramArguments" = (\n\t\t"%s";\n\t);\n};\n' \
      "\$(< "$box/loaded")" "\$(< "$box/loaded")"
    ;;
  managername) cat "$box/session" 2> /dev/null || print Aqua ;;
esac
STUB
  chmod +x "$box/stub/launchctl"
}

# run_setup <box> [base folder]. SHRINKIT_REPO is deliberately left unset: finding presets/ and
# quick-action/ beside the script is the thing a Homebrew install depends on.
run_setup() {
  local box="$1" base="${2:-$1/work}"
  sandboxed "$box"
  HOME="$box/home" SHRINKIT_DIR="$base" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
    zsh "$OPTIMIZER" setup
}

# run_teardown <box> [base folder]. With no base folder the variable is unset, which is how a
# custom install is usually torn down: from a new shell that never exported it.
run_teardown() {
  local box="$1" base="${2:-}"
  sandboxed "$box"
  if [[ -n "$base" ]]; then
    HOME="$box/home" SHRINKIT_DIR="$base" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" \
      zsh "$OPTIMIZER" teardown
  else
    HOME="$box/home" SHRINKIT_LAUNCHCTL="$box/stub/launchctl" zsh "$OPTIMIZER" teardown
  fi
}

plist_value() {
  plutil -extract "$2" raw -o - "$1" 2> /dev/null
}
links_to() {
  [[ -L "$1" && "${1:A}" == "${2:A}" ]]
}
is_dir() {
  [[ -d "$1" && ! -L "$1" ]]
}
action_count() {
  print -r -- "${#${(@f)$(print -rl -- "$1"/shrinkit:*.workflow(N))}}"
}

# A cask-shaped install: the release staged whole under Caskroom/<token>/<version>/shrinkit-<version>,
# the way a GitHub tag tarball unpacks, and the binary stanza's link in the prefix's own bin.
brew_cask() {
  local box="$1" staged="$1/brew/Caskroom/shrnkit/9.9/shrinkit-9.9"
  mkdir -p "$staged" "$box/brew/bin" "$box/home"
  cp "$OPTIMIZER" "$staged/shrinkit.sh"
  chmod +x "$staged/shrinkit.sh"
  cp -R "$REPO_DIR/quick-action" "$REPO_DIR/presets" "$REPO_DIR/lib" "$REPO_DIR/settings.conf" "$staged/"
  ln -sfn "$staged/shrinkit.sh" "$box/brew/bin/shrinkit"
}

# The command a Quick Action runs: where the script has to write its own path down.
action_command() {
  plutil -extract actions.0.action.ActionParameters.COMMAND_STRING raw -o - \
    "$1/Contents/document.wflow" 2> /dev/null
}
