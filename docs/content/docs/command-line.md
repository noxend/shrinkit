---
title: Command line
description: Every subcommand and flag.
---

```
shrinkit [--setting value ...] [file ...]
shrinkit config [show | edit | folder [<path>] | <setting> <value>]
shrinkit preset [add <name> | edit <name> | remove <name> | sync]
shrinkit edit <file>...
shrinkit run <file>
shrinkit merge <file>...
shrinkit setup | teardown
shrinkit doctor
```

`shrinkit --help` prints the full usage.

`shrinkit clip.mov ...` shrinks those files, each result beside its source under the
[result name](/docs/right-click/#result-names) rule. A name that is not a `.mov`, `.mp4` or `.m4v`
file is skipped. `shrinkit` with no files shrinks what waits in `input/`, as the
[watch folder](/docs/watch-folder/) does.

## Flags

| Flag | What it does |
| --- | --- |
| `--<setting> <value>` | A setting for this run, `_` written as `-`: `--crf 24`, `--max-height 720`. |
| `--<setting>`, `--no-<setting>` | A true/false setting on or off, with no value: `--remove-audio`, `--no-notify`. |
| `--preset <name>` | A preset from `presets/`. |
| `--cut <range>` | A stretch to cut out. Repeat for more. |
| `--keep <range>` | A stretch to keep, the rest cut. Repeat for more. |

How flags combine with a preset and `settings.conf` is under [Layering](/docs/presets/#layering). A
flag value that does not fit is replaced by the built-in default, not the value in `settings.conf`, and the log says so. An unknown flag, or
one missing its value, stops the run. `--cut` and `--keep` need a file named, and not both at once;
see [Cut and keep](/docs/edit/#cut-and-keep).

## Subcommands

| Command | What it does |
| --- | --- |
| `config` | Shows and changes [settings](/docs/settings/), and moves the working folder. `shrinkit config show` is the same as `shrinkit config`. |
| `preset` | Lists, adds, edits, removes and syncs [presets](/docs/presets/). |
| `edit <file>...` | Writes or opens an [edit file](/docs/edit/) for up to 10 recordings, and runs it when the editor exits without an error (see [Cut and edit](/docs/edit/#several-recordings)). |
| `run <file>` | Runs an edit file in this terminal. |
| `merge <file>...` | [Joins](/docs/merge/) 2 to 10 recordings without shrinking them. |
| `setup` | Creates the folders, the watcher and the right-click entries. Homebrew runs it on install and upgrade. |
| `teardown` | Undoes `shrinkit setup` and leaves the working folder. Homebrew runs it on upgrade and uninstall. |
| `doctor` | [Checks the install](/docs/troubleshooting/) and changes nothing. |

## Editors

`shrinkit edit` opens the edit file in `$VISUAL`, else `$EDITOR`, else `vi`. `shrinkit config edit`
and `shrinkit preset` open files in `$VISUAL`, else `$EDITOR`, else your default text editor.

## Working folder

`SHRINKIT_DIR` set in a shell names the working folder for that shell, in place of the one
`shrinkit setup` saved.
