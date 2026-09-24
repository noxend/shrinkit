# Sourced by tests/run-tests.sh: doctor's working-folder check.

test_doctor_fails_when_the_folder_was_moved_away() {
  local box out code=0
  box="$(installed_box)"
  mv "$box/work" "$box/moved"

  out="$(run_doctor "$box" 2>&1)" || code=$?

  check "fails, saying it is not there" \
    test "$(doctor_line "$out" folder)" = "FAIL  folder         $box/work does not exist"
  check "says how to point shrinkit at it again" \
    contains "$(doctor_block "$out" folder)" "  shrinkit config folder <path>"
  check "and exits 1" test "$code" = 1
}

test_doctor_says_a_folder_on_a_drive_needs_the_drive() {
  local box out drive="/Volumes/shrinkit-no-such-drive-$$"
  box="$(installed_box)"
  # What an ejected drive leaves: the folder file still names a folder on it.
  print -r -- "$drive/work" > "$box/home/Library/Application Support/shrinkit/folder"

  out="$(run_doctor "$box" 2>&1)"

  check "fails" test "$(doctor_line "$out" folder)" = "FAIL  folder         $drive/work does not exist"
  check "saying to connect the drive" contains "$(doctor_block "$out" folder)" "Connect the drive"
}

test_doctor_fails_when_the_folder_cannot_be_written_to() {
  local box out
  box="$(installed_box)"
  # What a read-only drive or a folder owned by root looks like. The folder itself matters as much
  # as input/: a run takes its lock there.
  chmod 555 "$box/work/input" "$box/work"

  out="$(run_doctor "$box" 2>&1)"
  chmod 755 "$box/work/input" "$box/work"

  check "fails, naming where it cannot write" \
    test "$(doctor_line "$out" folder)" = "FAIL  folder         cannot write to $box/work, $box/work/input"
  check "and says how to" contains "$(doctor_block "$out" folder)" "  chmod u+w '$box/work' '$box/work/input'"
}

test_doctor_warns_when_the_shell_names_another_folder() {
  local box out code=0
  box="$(installed_box)"
  mkdir -p "$box/other"

  # An export left in a shell's startup file from an earlier install.
  out="$(run_doctor "$box" SHRINKIT_DIR="$box/other" 2>&1)" || code=$?

  check "warns" test "$(doctor_line "$out" folder)" = \
    "warn  folder         SHRINKIT_DIR in this shell is $box/other, the watcher's folder is $box/work"
  check "and exits 0" test "$code" = 0
}
