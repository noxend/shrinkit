# shrinkit

[![tests](https://github.com/noxend/shrinkit/actions/workflows/tests.yml/badge.svg)](https://github.com/noxend/shrinkit/actions/workflows/tests.yml)

shrinkit compresses macOS screen recordings and speeds them up. Drop a `.mov` into a folder, or
right-click it in Finder, and a much smaller `.mp4` comes back. A QuickTime capture that started at
a few hundred megabytes usually ends up in single digits.

A raw screen capture is almost always too big to attach to a pull request, a Jira ticket or a Slack
message, and too slow to sit through. Playing it back at 2x and re-encoding it at a fixed quality
deals with both at once.

The encoding is ffmpeg. A launchd agent watches the folder for you, so the whole thing runs without
an app to open. Every part of it is configurable, and it can also cut a stretch out of the middle,
to shorten a recording or redact something in it.

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
shortcut on your Desktop. Run it again any time to update; it never overwrites your settings.

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

Most of the right-click menu is the list of your presets. Every file in `presets/` gets an entry
named after it, so out of the box you get `shrinkit: default`, which uses your settings as they
are, and `shrinkit: chat`, tuned for something going into a chat or a ticket. The smaller copy
lands beside the original, which stays where it is, and you can select several files to do them
together.

Add a preset and it becomes a new entry; the installer rebuilds the menu from `presets/` every
time it runs. One entry isn't a preset: `shrinkit: mark cuts`, for marking a stretch to remove
before shrinking (see below).

## One-off changes on the command line

Every setting doubles as a flag, so one file can be handled differently without editing anything:

```bash
shrinkit --speed 4 --crf 32 recording.mov
shrinkit --no-remove-audio recording.mov
```

A true/false setting takes no value: `--remove-audio` turns it on and `--no-remove-audio` turns it
off. Name no files and the flags apply to whatever is sitting in `input/`. Flags beat the config
file.

## Cutting a stretch out of the middle

Right-click a recording and choose `shrinkit: mark cuts`. It opens the recording, so you can find
the moment, and a `<recording>.cuts` text file next to it (creating one the first time) where you
mark what to remove, one range per line:

```
# clip.mov.cuts
0:32-0:35
1:10-1:12.5
```

Save it, then process the recording as usual: drop it into `input/` or right-click it and pick a
preset. Each range is removed entirely, not just skipped past on playback, since the frames are
never written to the output at all. Good for cutting a secret out of a recording, a password typed
into a form, a private chat glanced at mid-recording, and works just as well for plain shortening.

Times are `M:SS`, `M:SS.f`, or plain seconds. `#` starts a comment, a range under a tenth of a
second is too short to reliably land on a real frame, and a line that does not parse is skipped
rather than stopping the run. All three are logged, so check the log if a cut you expected does
not show up in the result. If you edit the file in TextEdit rather than through the menu entry,
save it as plain text (Format > Make Plain Text) with Smart Dashes off (Edit > Substitutions), or
it will not parse as written.

Cutting needs a steady frame rate to land exactly where it is told to, so a recording gets
resampled to `fps` (30 if `fps = 0`) before anything is removed, even when `fps = 0` would
otherwise mean "keep the original" for the rest of the recording.

Dropping a recording into `input/` files the `.cuts` sidecar away with the original once
processing is done. Right-clicking a file directly leaves both in place, the same way it leaves
the recording itself in place. Once you have the result, check it and clean up the source
yourself.

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
| `max_height` | Downscale tall videos to this height; `0` keeps the original | `0` |
| `output_suffix` | Added to the output name. `{speed}` becomes the speed, so the name follows it | `-{speed}x` |
| `keep_original` | `true` files the original in `.processed/`, `false` deletes it | `true` |
| `keep_days` | Delete originals from `.processed/` once this many days old, up to 3650; `0` keeps them forever | `0` |
| `notify` | Post a macOS banner when a file is done | `true` |
| `notify_sound` | `Glass`, `Ping`, `Pop`, `Hero` and the rest, or `none` | `Glass` |
| `notify_start` | Also post a quiet banner when a file starts | `true` |
| `copy_to_clipboard` | Put the finished file on the clipboard, ready to paste | `false` |

Logs go to a hidden `.logs/` folder. The watched folder is fixed when you install, because launchd
wants an absolute path; to move it, run the installer again with `SHRINKIT_DIR`. To have results
land somewhere else, a synced folder for instance, replace `output/` with a symlink to it.

System Settings > Login Items will list `shrinkit` from an unidentified developer. That is your own
script rather than a signed application, so there is nothing to sign.

## Update and uninstall

```bash
./update.sh      # pull and reinstall; settings and recordings are untouched
./uninstall.sh   # remove the agent, the script and the menu entries
```

Uninstalling leaves your recordings and settings where they are.

## License

MIT
