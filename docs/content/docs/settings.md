---
title: Settings
description: settings.conf, the config command, every setting, and the banners.
---

`settings.conf` in the working folder holds the settings every run starts from. A
[preset](/docs/presets/#layering) and flags can go on top of it.

```bash
shrinkit config                          # the values in effect
shrinkit config crf 32                   # change one
shrinkit config edit                     # open settings.conf
shrinkit config folder                   # print the working folder
shrinkit config folder ~/Movies/clips    # use another folder
```

`shrinkit config <setting> <value>` refuses a value that does not fit, and keeps the file's
comments. `shrinkit config edit` opens the file in [your editor](/docs/command-line/#editors).

`shrinkit config folder <path>` copies `settings.conf` and the presets along when the old folder has
a `settings.conf` and the new one has none. Recordings and results stay in the old folder. When the
watcher is installed, `shrinkit config folder` runs `shrinkit setup` again for the new folder, which
moves the watcher, the right-click entries and the Desktop link to it.

A working folder inside `~/Desktop`, `~/Documents` or `~/Downloads` needs Full Disk Access.
`shrinkit setup` prints the steps; until they are done, `input/` is not processed.

## Every setting

| Setting | Default | Takes | What it does |
| --- | --- | --- | --- |
| `speed` | `2` | a number above 0 | Playback speed. `2` is twice as fast, `1` leaves it. |
| `fps` | `30` | 0 to 240 | Frame rate of the result, after the speed-up. `0` keeps the recording's own frame rate. |
| `crf` | `28` | 0 to 51 | Quality. Lower is sharper and bigger, higher is smaller. |
| `codec` | `h264` | `h264`, `hevc` | The video codec. |
| `remove_audio` | `true` | `true`, `false` | `true` drops the sound. `false` keeps it, sped up to match. |
| `max_height` | `0` | 0 to 9999 | Scales a taller video down to this height, keeping its shape. `0` keeps the size. |
| `keep_original` | `true` | `true`, `false` | Watch folder: `true` moves the original to `.processed/`, `false` deletes it. |
| `keep_days` | `0` | 0 to 3650 | Watch folder: deletes originals from `.processed/` after this many days. `0` keeps them. |
| `notify` | `true` | `true`, `false` | Posts the banners below. |
| `notify_sound` | `Glass` | a sound name, or `none` | The banners' sound. |
| `notify_start` | `true` | `true`, `false` | Also posts a banner, without sound, when a file starts. |
| `copy_to_clipboard` | `false` | `true`, `false` | Puts the finished file on the clipboard. |

One `key = value` per line. A line starting with `#` is a comment; a `#` elsewhere is part of the
value. A value that does not fit is replaced by its default, and a key that is not a setting is
ignored; `.logs/optimizer.log` says so either way. Every setting is also a
[flag](/docs/command-line/#flags).

## Banners

Every run reports through macOS notifications:

- when a file starts: `Optimizing…` and its name
- when it is done: its name and the size before and after
- when it fails: `Could not shrink` and its name
- when ffmpeg or ffprobe cannot be found, or the preset sets nothing

A [merge](/docs/merge/) posts `Merging…` when it starts, a banner when it is done, and one titled
`Could not merge` when the join fails. An [edit run](/docs/edit/) posts one banner at the end.

`notify = false` turns all of them off. `notify_start = false` turns off the ones posted when a file or a merge starts.
