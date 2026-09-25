# Sourced by tests/run-tests.sh: running shrinkit edit and run against a sandbox, with an editor,
# open and osascript that write down what they were asked for instead of doing it.

# --------------------------------------------------------------------- edit and run

# stub_tools <dir>: open and osascript in <dir>, each writing one line per call to <dir>/<name>.log.
# osascript's line says what the script it was handed on stdin does (banner or clipboard), then its
# arguments after the '-', separated by ' | '.
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
print -r -- "\$kind \${(j: | :)@[4,-1]}" >> ${(qq)dir}/osascript.log
STUB
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
# the edits of the editor in <tools>, which is cancelled so the file is left to run by hand.
make_edit() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$tools"
  : > "$tools/cancel"
  run_edit "$box" "$tools" "$@" 2> /dev/null
  rm -f "$tools/cancel"
}

# run_file <box> <tools> <args...>: shrinkit run, with open and osascript from <tools>.
run_file() {
  local box="$1" tools="$2"
  shift 2
  sandboxed "$box"
  sandboxed "$tools"
  PATH="$tools:$PATH" SHRINKIT_DIR="$box" SHRINKIT_REPO="" zsh "$OPTIMIZER" run "$@"
}

# The block headers of an edit file, one per line, in the order they are written.
headers_of() {
  grep '^\[' "$1"
}
