#!/bin/zsh
# Sourced by shrinkit, not run on its own: every helper here reads the settings and the paths the
# main script sets up first.

# --------------------------------------------------------------------- the Terminal window

# The Terminal window a right-click entry shows a run in: the launcher it opens on, the queue that
# hands each window its file, and the step that closes it afterwards.

# shrinkit: run opens a Terminal window on this launcher for each edit file it is handed. setup
# writes it once beside the folder file, as it writes the plist and the folder file themselves, so
# no file written at click time is ever handed to Terminal. Each edit file leaves its path in the
# queue beside it, one request per file, and each window takes the oldest.
EDIT_LAUNCHER="${FOLDER_FILE:h}/shrinkit edit.command"
EDIT_QUEUE="${FOLDER_FILE:h}/edit-queue"

# The request for file left in the queue, then a Terminal window opened on the launcher to take it.
# When no window opens the request goes too, or the next window, which takes the oldest, would run
# this file instead of its own.
start_edit_window() {
  local file="$1" request queued
  mkdir -p "$EDIT_QUEUE" && request="$(mktemp "$EDIT_QUEUE/.new.XXXXXX")" || return 1
  queued="$EDIT_QUEUE/${${request:t}#.new.}"
  # Written under a hidden name and renamed once whole, so no window takes a request half written.
  print -r -- "$file" > "$request" && mv "$request" "$queued" || return 1
  open -a Terminal "$EDIT_LAUNCHER" && return 0
  rm -f "$queued"
  return 1
}

# The launcher runs the folder and the program every right-click entry runs.
write_edit_launcher() {
  mkdir -p "${EDIT_LAUNCHER:h}" \
    && print -rl -- '#!/bin/zsh' "SHRINKIT_DIR=${(qq)BASE_DIR} ${(qq)$(registered_path)} run --next" \
      > "$EDIT_LAUNCHER" \
    && chmod +x "$EDIT_LAUNCHER"
}

# The oldest request in the queue, taken so that no other window takes it too: mv is a rename, and
# of two windows renaming one request only one succeeds. A request whose file is gone is dropped,
# and so is one left 2 minutes ago or more: a window reaches this within seconds of its click, so
# the window that request was for never came (closed while its shell started, or Terminal quit),
# and taken now it would run in a window opened for a later click. The hidden ones go at 2 minutes
# too: a request is written or taken under a hidden name for a moment, and one still there was left
# by a process that ended in between. Prints the edit file's path, and fails when none is waiting.
take_edit_request() {
  local request mine="$EDIT_QUEUE/.taken.$$" file
  rm -f "$EDIT_QUEUE"/*(DN.mm+1)
  for request in "$EDIT_QUEUE"/*(N.mm-2Om); do
    mv "$request" "$mine" 2> /dev/null || continue
    file="$(< "$mine")"
    rm -f "$mine"
    [[ -f "$file" ]] || continue
    print -r -- "$file"
    return 0
  done
  return 1
}

# The id of the Terminal window whose selected tab is on the terminal tty, asked for as the run
# starts, while the tab Terminal just opened for it is still the selected one. Nothing when no window
# says so. A window whose tab cannot answer is passed over rather than ending the search.
terminal_window() {
  local id
  id="$(
    osascript -l AppleScript - "$1" 2> /dev/null << 'WINDOW'
on run argv
  tell application "Terminal"
    repeat with w in windows
      try
        if tty of selected tab of w is (item 1 of argv) then return id of w
      end try
    end repeat
  end tell
end run
WINDOW
  )"
  is_int "$id" && print -r -- "$id"
}

# Terminal keeps a window open once its shell has ended, so the window asks Terminal to close it:
# from a step that outlives this process, 3 seconds on, when the shell around it has ended, the
# window of the id terminal_window found, by its id since by then Terminal may have given the tty
# to a window opened meanwhile. Asked by tty, Terminal closed it without a prompt (measured
# 2026-09-25). Only while it holds the one tab, still on that tty: closing a window closes every tab
# in it, and Terminal may have opened this one as a tab beside the user's own.
close_window_later() {
  local id="$1" tty="$2"
  (
    sleep 3
    osascript -l AppleScript - "$id" "$tty" << 'CLOSE'
on run argv
  tell application "Terminal"
    try
      set w to window id ((item 1 of argv) as integer)
      if (count of tabs of w) is 1 and tty of tab 1 of w is (item 2 of argv) then close w
    end try
  end tell
end run
CLOSE
  ) < /dev/null > /dev/null 2>&1 &|
}
