# shrinkit

[![tests](https://github.com/noxend/shrinkit/actions/workflows/tests.yml/badge.svg)](https://github.com/noxend/shrinkit/actions/workflows/tests.yml)

shrinkit compresses macOS screen recordings and speeds them up. Drop a `.mov` into a folder, or
right-click it in Finder, and a much smaller `.mp4` comes back. A QuickTime capture that started at
a few hundred megabytes usually ends up in single digits.

A raw screen capture is almost always too big to attach to a pull request, a Jira ticket or a Slack
message, and too slow to sit through. Playing it back at 2x and re-encoding it at a fixed quality
deals with both at once.

The encoding is ffmpeg. A launchd agent watches the folder for you, so the whole thing runs without
an app to open. Every part of it is configurable, and it can also cut out the stretches where
nothing on screen is moving.

## Demo

https://github.com/user-attachments/assets/651900d7-0171-4793-b6fd-5d1d5097ee98

## Requirements

- macOS
- [ffmpeg](https://ffmpeg.org). The installer offers to fetch it with [Homebrew](https://brew.sh)
  if you do not have it.

## Install

```bash
git clone https://github.com/noxend/shrinkit.git
cd shrinkit
./install.sh
```

The installer copies the script to `~/.local/bin/shrinkit`, creates the working folders under
`~/Movies/shrinkit`, registers a launchd agent that watches `input/`, and puts a `shrinkit`
shortcut on your Desktop. Run it again any time to update; it never overwrites your settings. Set
`DESKTOP_SHORTCUT=0` to skip the shortcut and `QUICK_ACTION=0` to skip the right-click menu entry.

For a different working folder:

```bash
SHRINKIT_DIR="$HOME/Movies/clips" ./install.sh
```

`~/Desktop`, `~/Documents` and `~/Downloads` are guarded by macOS privacy protection, and a
background job is refused there until you grant it Full Disk Access by hand. If you install into
one of them the script prints the steps. Anywhere else, `~/Movies` included, needs nothing.

## Use

1. Open the `shrinkit` shortcut on your Desktop and drop a recording into `input/`. QuickTime
   `.mov`, `.mp4` and `.m4v` all work.
2. Give it a few seconds.
3. Collect the result from `output/`, converted to `.mp4` and named `clip-2x.mp4`.

The original goes to a hidden `.processed/` folder, so the working folder holds only
`settings.conf`, `presets/`, `input/` and `output/`.

## Right-click a video

The right-click menu is the list of your presets. Every file in `presets/` gets an entry named
after it, so out of the box you get `shrinkit: default`, which uses your settings as they are,
and `shrinkit: chat`, tuned for something going into a chat or a ticket. The smaller copy lands
beside the original, which stays where it is, and you can select several files to do them
together.

Add a preset and it becomes a new entry; the installer rebuilds the menu from `presets/` every
time it runs.

## One-off changes on the command line

Every setting doubles as a flag, so one file can be handled differently without editing anything:

```bash
shrinkit --speed 4 --crf 32 recording.mov
shrinkit --trim-idle --no-remove-audio recording.mov
```

A true/false setting takes no value: `--trim-idle` turns it on and `--no-trim-idle` turns it off.
Name no files and the flags apply to whatever is sitting in `input/`. Flags beat the config file.

## Presets

A preset is a file of the same settings in `presets/`, read on top of `settings.conf`. Whatever it
leaves out stays as the config has it. `default.conf` sets nothing at all, which is how the plain
settings get a place in the menu alongside the rest.

```bash
shrinkit --preset chat recording.mov
```

Copy a preset file to make your own, then give it a menu entry without reinstalling:

```bash
shrinkit preset list
shrinkit preset install tiny     # adds "shrinkit: tiny" to the right-click menu
shrinkit preset remove tiny      # takes the entry out, keeps the file
```

Flags beat a preset, and a preset beats the config file.

## Settings

From the command line:

```bash
shrinkit config              # what is in effect right now
shrinkit config crf 32       # change one
shrinkit config edit         # open it in $EDITOR
```

Or edit `~/Movies/shrinkit/settings.conf` yourself. It is one `key = value` per line, and a line
starting with `#` is a comment. Changes take effect on the next recording. A value you get wrong
goes back to its default and the log says so, and a line that makes no sense is skipped, so a typo
here will never leave a recording unprocessed.

| Setting | What it does | Default |
| --- | --- | --- |
| `speed` | Speed multiplier. `2` is twice as fast, `1` leaves it alone | `2` |
| `fps` | Cap the frame rate, up to 240; `0` keeps the original | `30` |
| `crf` | Quality against size, the main knob. Lower is sharper and bigger, higher is smaller (18 high, 23 good, 28 small, 32 tiny) | `28` |
| `codec` | `h264` plays everywhere, `hevc` is about 30% smaller and less compatible | `h264` |
| `remove_audio` | `true` drops the sound, `false` keeps it and speeds it up to match | `true` |
| `trim_idle` | Cut out the stretches where nothing on screen changes. Skipped when the audio is kept | `false` |
| `max_height` | Downscale tall videos to this height; `0` keeps the original | `0` |
| `output_suffix` | Added to the output name. `{speed}` becomes the speed, so the name follows it | `-{speed}x` |
| `keep_original` | `true` files the original in `.processed/`, `false` deletes it | `true` |
| `keep_days` | Delete originals from `.processed/` once this many days old, up to 3650; `0` keeps them forever | `0` |
| `notify` | Post a macOS banner when a file is done | `true` |
| `notify_title` | Banner title | `Video optimized` |
| `notify_sound` | `Glass`, `Ping`, `Pop`, `Hero` and the rest, or `none` | `Glass` |
| `notify_start` | Also post a quiet banner when a file starts | `true` |
| `copy_to_clipboard` | Put the finished file on the clipboard, ready to paste | `false` |
| `check_updates` | Once a day, say if the repo has newer commits | `true` |
| `output_dir` | Absolute path to send results somewhere else, a synced folder for instance | empty |

Logs go to a hidden `.logs/` folder. The watched folder is fixed when you install, because launchd
wants an absolute path; to move it, run the installer again with `SHRINKIT_DIR`.

System Settings > Login Items will list `shrinkit` from an unidentified developer. That is your own
script rather than a signed application, so there is nothing to sign.

If you used the tool before it was called shrinkit, `./install.sh` takes the old install apart,
moves `~/Movies/demo-recordings` across, and converts `settings.jsonc` to the current format,
keeping the old file as `settings.jsonc.bak`.

## Update and uninstall

```bash
./update.sh      # pull and reinstall; settings and recordings are untouched
./uninstall.sh   # remove the agent, the script and the menu entries
```

Uninstalling leaves your recordings and settings where they are.

## License

MIT
