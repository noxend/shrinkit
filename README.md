# Demo Video Optimizer

Drop a screen recording into a folder and get back a faster, smaller, easy-to-share copy. It runs
by itself in the background on macOS: no app to open, no buttons to press. Handy for trimming long
demo recordings down before attaching them to a ticket or a chat.

By default it plays the recording back at 2x, drops the audio, caps the frame rate, and re-encodes
with a quality-based codec (CRF), so the file comes out much smaller. Every part is configurable.

## Demo

https://github.com/user-attachments/assets/651900d7-0171-4793-b6fd-5d1d5097ee98

## Requirements

- macOS
- [ffmpeg](https://ffmpeg.org) (the installer offers to install it via [Homebrew](https://brew.sh) if it is missing)

## Install

```bash
git clone git@github.com:noxend/demo-video-optimizer.git
cd demo-video-optimizer
./install.sh
```

That copies the script into `~/.local/bin`, creates the working folders under
`~/Movies/demo-recordings`, installs the config, registers a launchd agent that watches the input
folder, and puts a **`demo-recordings` shortcut on your Desktop** pointing at that folder. So the
work happens in a non-protected location (no permissions needed) while you reach `input/` and
`output/` from the Desktop. Re-running `./install.sh` updates everything and never overwrites your
settings. Pass `DESKTOP_SHORTCUT=0` to skip the shortcut.

To use a different base folder:

```bash
DEMO_OPTIMIZER_DIR="$HOME/Desktop/demo-recordings" ./install.sh
```

You can put it on the `~/Desktop` (or in `~/Documents` / `~/Downloads`), but those are
macOS privacy-protected: a background job is denied there, with no automatic prompt, until you grant
it **Full Disk Access** once by hand. When you install into one of them the script prints the exact
steps (add `~/.local/bin/demo-video-optimizer` in System Settings > Privacy & Security > Full Disk
Access, then reload the agent). Anywhere else, for example the default `~/Movies`, needs no such step.

## Use

1. Open the `demo-recordings` shortcut on your Desktop and drop a recording (`.mov`, `.mp4`,
   `.m4v`) into `input/`.
2. Wait a few seconds. It is processed automatically.
3. Take the result from `output/` (named `clip-2x.mp4`).

The original is moved to a hidden `.processed/` folder as a backup, so the base folder shows only
`settings.jsonc`, `input/` and `output/`.

## Settings

Edit `~/Movies/demo-recordings/settings.jsonc` (JSON with `//` comments allowed). Changes apply to
the next recording. A bad value falls back to its default, and if the whole file is not valid JSON
the run uses the defaults, so nothing breaks.

| Setting | What it does | Default |
| --- | --- | --- |
| `SPEED` | Speed multiplier. `2` = twice as fast, `1.5`, `1` = original | `2` |
| `FPS` | Cap the frame rate (60fps recordings halve to 30); `0` keeps original | `30` |
| `CRF` | Quality/size, the main size knob. Lower = bigger/sharper, higher = smaller (18 high, 23 good, 28 small, 32 tiny) | `28` |
| `CODEC` | `h264` (plays everywhere) or `hevc` (~30% smaller again, less compatible) | `h264` |
| `REMOVE_AUDIO` | `true` drops sound; `false` keeps it and speeds it up to match | `true` |
| `MAX_HEIGHT` | Downscale tall videos to this height; `0` keeps the original | `0` |
| `OUTPUT_SUFFIX` | Text added to the output name | `-2x` |
| `KEEP_ORIGINAL` | `true` keeps the original in `.processed/`; `false` deletes it | `true` |
| `NOTIFY` | `true` posts a macOS banner when each file is done | `true` |
| `NOTIFY_TITLE` | Banner title text | `Video optimized` |
| `NOTIFY_SOUND` | Banner sound (`Glass`, `Ping`, `Pop`, `Hero`, ...) or `none` for silent | `Glass` |
| `COPY_TO_CLIPBOARD` | `true` puts the finished file on the clipboard, ready to paste | `false` |
| `CHECK_UPDATES` | Once a day, notify if the repo has newer commits (then run `update.sh`) | `true` |
| `OUTPUT_DIR` | Full path to send results elsewhere (e.g. a synced folder); empty = `output/` | empty |

The notification is the standard macOS banner (posted via `osascript`, no extra tools). Its icon is
the Script Editor icon and can't be changed from a script; only the title and sound are adjustable.

Encoding is quality-based (libx264/libx265 CRF), which is far smaller than a fixed bitrate for
screen recordings. On a sample screen capture the old fixed-bitrate path produced a file *larger*
than the source; the CRF path made it several times smaller.

Logs are written to a hidden `.logs/` folder inside the base folder. The watched input folder is
fixed at install time (a launchd limitation); to move it, re-run the installer with
`DEMO_OPTIMIZER_DIR`.

macOS lists the background item under System Settings > Login Items as **demo-video-optimizer** from
an unidentified developer. That is expected: it is your own local script, not a signed app.

## How it works

A [launchd](https://www.launchd.info) agent with a `WatchPaths` entry on the input folder runs the
installed script (`~/.local/bin/demo-video-optimizer`) whenever the folder changes. It waits for the dropped file to
finish writing, reads `settings.jsonc`, and calls ffmpeg with `setpts` for the speed change, an
optional `scale` filter, `h264_videotoolbox`/`hevc_videotoolbox` for hardware encoding, and
`+faststart` so the file streams immediately. A `mkdir`-based lock keeps overlapping events from
processing the same file twice.

## Tests

```bash
./tests/run-tests.sh          # everything
./tests/run-tests.sh lock     # only the tests whose name contains "lock"
```

Each test runs the real script against a throwaway folder under `/tmp`, so your own recordings and
the installed agent are left alone. Sample videos are generated with ffmpeg into `tests/fixtures`
on the first run and reused afterwards; they are not committed.

## Update

```bash
./update.sh
```

Pulls the latest version and re-installs it. Your settings and recordings are untouched.

## Uninstall

```bash
./uninstall.sh
```

Removes the agent and the script. Your recordings and settings are left in place.

## License

MIT
