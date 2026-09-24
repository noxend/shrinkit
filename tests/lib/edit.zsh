# Sourced by tests/run-tests.sh: running shrinkit edit and run against a sandbox, with an editor,
# open and osascript that write down what they were asked for instead of doing it.

# --------------------------------------------------------------------- edit and run

# stub_tools <dir>: open and osascript in <dir>, each writing one line per call to <dir>/<name>.log.
# osascript's line says what the script it was handed on stdin does (banner, clipboard, window for
# finding the Terminal window a run is in, or close for closing one), then its arguments after the
# '-', separated by ' | '. Asked for a window, it answers with the id in <dir>/window-id: 4242, or
# nothing once a test removes that file.
stub_tools() {
  local dir="$1"
  sandboxed "$dir"
  print -rl -- '#!/bin/zsh' "print -r -- \"\${(j: | :)@}\" >> ${(qq)dir}/open.log" > "$dir/open"
  cat > "$dir/osascript" << STUB
#!/bin/zsh
script="\$(cat)"
kind=other
[[ "\$script" == *displayNotification* ]] && kind=banner
[[ "\$script" == *NSPasteboard* ]] && kind=clipboard
[[ "\$script" == *'return id of w'* ]] && kind=window
[[ "\$script" == *'close w'* ]] && kind=close
print -r -- "\$kind \${(j: | :)@[4,-1]}" >> ${(qq)dir}/osascript.log
[[ "\$kind" == window && -f ${(qq)dir}/window-id ]] && cat ${(qq)dir}/window-id
exit 0
STUB
  print -r -- 4242 > "$dir/window-id"
  chmod +x "$dir/open" "$dir/osascript"
}

# stub_editor <dir> <name> <edit lines...>: an editor called <name> in <dir>. It writes its name and
# the file it was handed to <dir>/editor.log, keeps a copy of the file as it was handed over in
# <dir>/given, then runs the edit lines as zsh, with $file set and the helpers below:
#   add <block> <line...>   the lines go right under the block's [header]
#   top <line...>           the lines go right under the merge line, above the first block
#   set_merge <value>       the merge line at the top says merge = <value>
#   drop_blocks             every block goes, from the first [header] on
# An edit line of 'exit 1' is an editor that fails, and so is any editor while <dir>/cancel exists.
stub_editor() {
  local dir="$1" name="$2"
  shift 2
  sandboxed "$dir"
  {
    print -r -- '#!/bin/zsh'
    print -r -- "dir=${(qq)dir}"
    cat << 'HELPERS'
file="$1"
print -r -- "${0:t} $file" >> "$dir/editor.log"
cp "$file" "$dir/given"
add() {
  HEADER="[$1]" TEXT="${(F)@[2,-1]}" awk '{ print } $0 == ENVIRON["HEADER"] { print ENVIRON["TEXT"] }' \
    "$file" > "$file.new" && mv "$file.new" "$file"
}
top() {
  TEXT="${(F)@}" awk '{ print } /^merge = / { print ENVIRON["TEXT"] }' \
    "$file" > "$file.new" && mv "$file.new" "$file"
}
set_merge() {
  VALUE="$1" awk '/^merge = / { print "merge = " ENVIRON["VALUE"]; next } { print }' \
    "$file" > "$file.new" && mv "$file.new" "$file"
}
drop_blocks() {
  awk '/^\[/ { exit } { print }' "$file" > "$file.new" && mv "$file.new" "$file"
}
HELPERS
    print -rl -- "$@"
    print -r -- '[[ -f "$dir/cancel" ]] && exit 1'
    print -r -- 'exit 0'
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

# run_edit <box> <tools dir> <args...>: shrinkit edit with the editor called 'editor' in the tools
# dir, and its open and osascript first on the PATH. VISUAL is cleared, since the machine running
# the tests may have one of its own that would win.
run_edit() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$box"
  sandboxed "$tools"
  env -u VISUAL EDITOR="$tools/editor" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" \
    zsh "$OPTIMIZER" edit "$@"
}

# make_edit <box> <tools> <recording>...: the edit file shrinkit edit writes for the recordings, with
# the edits of the editor in <tools>, which is cancelled so the file is left to run by hand. Prints
# the file's path, as the editor was handed it.
make_edit() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$tools"
  : > "$tools/cancel"
  run_edit "$box" "$tools" "$@" 2> /dev/null
  rm -f "$tools/cancel"
  edited "$tools"
}

# The file the last editor in <tools> was handed.
edited() {
  local line
  line="$(tail -1 "$1/editor.log")"
  print -r -- "${line#* }"
}

# name_for <recording>...: the name SPEC.md gives the edit file of a set of recordings, from their
# absolute paths with links resolved: shrinkit-<code>.edit.txt, <code> the first 6 hex digits of
# the SHA-256 of the paths sorted byte by byte, one per line.
name_for() {
  local sum
  sum="$(print -rl -- ${^@:A} | LC_ALL=C sort | shasum -a 256)"
  print -r -- "shrinkit-${sum[1,6]}.edit.txt"
}

# run_file <box> <tools> <args...>: shrinkit run, with open and osascript from <tools>.
run_file() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$box"
  sandboxed "$tools"
  PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" run "$@"
}

# run_window <box> <tools> <args...>: shrinkit run with the arguments of the right-click entry or of
# the Terminal window, with open and osascript from <tools> and HOME in <box>, so the queue it
# writes and reads is the box's.
run_window() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$box"
  sandboxed "$tools"
  HOME="$box/home" PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" run "$@"
}

# run_entry <box> <tools> <entry> <file>...: the command of the right-click entry called <entry>
# in an install made by setup_box and run_setup, run the way a Quick Action runs it (zsh, the
# selected files as arguments), from inside the box, with HOME there and open and osascript from
# <tools>.
run_entry() {
  local box="$1" tools="$2" command
  sandboxed "$box"
  sandboxed "$tools"
  command="$(action_command "$box/home/Library/Services/shrinkit: $3.workflow")"
  shift 3
  [[ -n "$command" ]] || return 1
  (cd "$box" && HOME="$box/home" PATH="$tools:$PATH" zsh -c "$command" zsh "$@")
}

# in_terminal <tools> <command...>: the command on a terminal of its own, run by a shell with job
# control and followed by exit, the way Terminal runs a .command. The terminal's name goes to
# <tools>/tty first, and what the terminal shows to <tools>/screen, with its carriage returns.
in_terminal() {
  local tools="$1"
  shift
  sandboxed "$tools"
  script -q /dev/null zsh -o monitor -c 'tty > "$1"; shift; "$@"; exit' zsh "$tools/tty" "$@" \
    < /dev/null > "$tools/screen" 2>&1
}

# What <tools>/screen reads as, one line per line: in_terminal's screen without its carriage returns
# or its escape codes.
screen_text() {
  tr -d '\r' < "$1/screen" | sed -E $'s/\e\\[[0-9;?]*[A-Za-z]//g'
}

# The block headers of an edit file, one per line, in the order they are written.
headers_of() {
  grep '^\[' "$1"
}
