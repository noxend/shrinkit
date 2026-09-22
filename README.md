# shrinkit

[![tests](https://github.com/noxend/shrinkit/actions/workflows/tests.yml/badge.svg)](https://github.com/noxend/shrinkit/actions/workflows/tests.yml)

shrinkit compresses macOS screen recordings and speeds them up. Drop a `.mov` into a folder, or
right-click it in Finder, and a much smaller `.mp4` comes back. A QuickTime capture that started at
a few hundred megabytes usually ends up in single digits.

A raw screen capture is almost always too big to attach to a pull request, a Jira ticket or a Slack
message, and too slow to sit through. Playing it back at 2x and re-encoding it at a fixed quality
deals with both at once.

The encoding is ffmpeg. A launchd agent watches the folder for you, so the whole thing runs without
an app to open. Every part of it is configurable. It can cut a stretch out of the middle, to
shorten a recording or redact something in it, and it can join several takes into one before any
of that.

## Demo

https://github.com/user-attachments/assets/651900d7-0171-4793-b6fd-5d1d5097ee98

## Install

Needs macOS and [Homebrew](https://brew.sh). ffmpeg comes along with it.

```bash
brew install --cask noxend/tap/shrinkit
```

That sets everything up: a working folder at `~/Movies/shrinkit`, a watcher on its `input/`, the
right-click entries in Finder, a `shrinkit` shortcut on your Desktop and a `shrinkit` command.

## Use

**Drop a recording** into `input/` (open the Desktop shortcut). A few seconds later the result is
in `output/`, and the original is kept in the hidden `.processed/` folder.

**Right-click a recording** in Finder, wherever it is, and pick `shrinkit: 2x`, `shrinkit: sharp`
or `shrinkit: tiny`. The result lands beside it as `clip-2x.mp4`, `clip-sharp.mp4` or
`clip-tiny.mp4`, and the recording stays where it was. Select several to do them together.

**From the terminal**, name the file. Any setting works as a one-off flag:

```bash
shrinkit recording.mov
shrinkit --speed 4 --crf 32 recording.mov
shrinkit --preset tiny recording.mov
```

## Presets

| Preset | What it is |
| --- | --- |
| `2x` | The everyday one, twice as fast |
| `sharp` | Sharper and bigger, for a pull request |
| `tiny` | As small as it gets, at most 1080p |

A preset is a small file in `~/Movies/shrinkit/presets/` holding only the settings it changes. Copy
one to make your own, then give it a right-click entry:

```bash
shrinkit preset install mine     # adds "shrinkit: mine" to the menu
shrinkit preset remove mine      # takes it out, keeps the file
```

Flags beat a preset, and a preset beats `settings.conf`.

## Cutting a stretch out

Handy for shortening a recording, or for removing a password or a private chat that got captured.

Right-click the recording and pick `shrinkit: mark cuts`. It opens the video and a
`<recording>.cuts` file next to it. Write one range to remove per line, save, then shrink it as
usual:

```
0-0:20        the first 20 seconds
0:32-0:35
2:30-end      from 2:30 to the end
```

Or in one go from the terminal: `shrinkit --cut 0:32-0:35 recording.mov`, or `--keep 1:00-2:00`
to name what stays instead.

- Times are `M:SS`, `M:SS.f` or plain seconds. `0` is the start and `end` is the real end.
- `#` starts a comment. A line that does not make sense is skipped and written to the log.
- Edited in TextEdit, save as plain text with Smart Dashes off (Edit > Substitutions), or a range
  like `0–0:04` is skipped. The log says so.

## Joining recordings

Select several recordings, right-click, pick `shrinkit: merge`. They are joined into
`<first>-merged.mov` beside the first one, in the order they were recorded. To choose the order,
start the names with a number and a space: `1 intro.mov`, `2 bug.mov`.

Merging does not shrink, so run a preset on the result afterwards. Recordings of the same size and
format are joined as they are, which is quick; mixed ones are re-encoded to match into an `.mp4`.

## Settings

```bash
shrinkit config                          # what is in effect right now
shrinkit config crf 32                   # change one
shrinkit config edit                     # open settings.conf
shrinkit config folder ~/Movies/clips    # move the working folder
```

| Setting | What it does | Default |
| --- | --- | --- |
| `speed` | Speed multiplier. `2` is twice as fast, `1` leaves it alone | `2` |
| `fps` | Cap the frame rate, up to 240; `0` keeps the original | `30` |
| `crf` | Quality against size, the main knob. Lower is sharper and bigger, higher is smaller (18 high, 23 good, 28 small, 32 tiny) | `28` |
| `codec` | `h264` plays everywhere, `hevc` is about 30% smaller and less compatible | `h264` |
| `remove_audio` | `true` drops the sound, `false` keeps it and speeds it up to match | `true` |
| `max_height` | Downscale tall videos to this height; `0` keeps the original | `0` |
| `keep_original` | `true` files the original in `.processed/`, `false` deletes it | `true` |
| `keep_days` | Delete originals from `.processed/` once this many days old, up to 3650; `0` keeps them forever | `0` |
| `notify` | Post a macOS banner when a file is done | `true` |
| `notify_sound` | `Glass`, `Ping`, `Pop`, `Hero` and the rest, or `none` | `Glass` |
| `notify_start` | Also post a quiet banner when a file starts | `true` |
| `copy_to_clipboard` | Put the finished file on the clipboard, ready to paste | `false` |

A value that does not fit is replaced by its default, and the log in `.logs/` says so.

## Update and uninstall

```bash
brew upgrade --cask shrinkit
brew uninstall --cask shrinkit
```

Uninstalling removes the watcher, the right-click entries, the Desktop shortcut and the command.
Your recordings, results, settings and presets stay in the working folder. `brew uninstall --zap`
also forgets which working folder you chose.

If brew can no longer run it, the same by hand, then delete the shortcut on your Desktop, which
is named after the working folder:

```bash
launchctl bootout "gui/$(id -u)/com.shrinkit"
rm -f ~/Library/LaunchAgents/com.shrinkit.plist
rm -rf ~/Library/Services/shrinkit:*.workflow ~/.local/bin/shrinkit ~/.local/share/shrinkit
/System/Library/CoreServices/pbs -update
```

## Running from a clone

For working on shrinkit itself:

```bash
git clone https://github.com/noxend/shrinkit.git
cd shrinkit
./shrinkit.sh setup        # install from this checkout
./shrinkit.sh teardown     # undo it
./tests/run-tests.sh       # the test suite
```

A clone in `~/Desktop`, `~/Documents` or `~/Downloads` is copied to `~/.local` on setup, because
macOS does not let the watcher read those folders, so run `setup` again after a `git pull` there.

## License

MIT
