# Demo Video Optimizer

Drop a screen recording into a folder and get back a faster, smaller, easy-to-share copy. It runs
by itself in the background on macOS: no app to open, no buttons to press. Handy for trimming long
demo recordings down before attaching them to a ticket or a chat.

By default it plays the recording back at 2x, removes the audio, and re-encodes to a compact H.264
mp4 using Apple's hardware encoder. Every part of that is configurable in a plain text file.

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
`~/Movies/demo-recordings`, installs the config, and registers a launchd agent that watches the
input folder. Re-running `./install.sh` updates everything and never overwrites your settings.

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

1. Put a recording (`.mov`, `.mp4`, `.m4v`) into `~/Movies/demo-recordings/input`.
2. Wait a few seconds. It is processed automatically.
3. Take the result from `~/Movies/demo-recordings/output` (named `clip-2x.mp4`).

The original is moved to `processed/` as a backup.

## Settings

Edit `~/Movies/demo-recordings/settings.txt` (double-click opens it in TextEdit). Changes apply to
the next recording. A bad value falls back to its default, so a typo cannot break it.

| Setting | What it does | Default |
| --- | --- | --- |
| `SPEED` | Speed multiplier. `2` = twice as fast, `1.5`, `1` = original | `2` |
| `REMOVE_AUDIO` | `true` drops sound; `false` keeps it and speeds it up to match | `true` |
| `CODEC` | `h264` (plays everywhere) or `hevc` (~40% smaller, less compatible) | `h264` |
| `BITRATE` | `auto` picks from the video height, or set your own like `5000k` | `auto` |
| `MAX_HEIGHT` | Downscale tall videos to this height; `0` keeps the original | `0` |
| `OUTPUT_SUFFIX` | Text added to the output name | `-2x` |
| `KEEP_ORIGINAL` | `true` keeps the original in `processed/`; `false` deletes it | `true` |
| `OUTPUT_DIR` | Full path to send results elsewhere (e.g. a synced folder); empty = `output/` | empty |

Logs are written to the `logs/` folder inside the base folder. The watched input folder is fixed at
install time (a launchd limitation); to move it, re-run the installer with `DEMO_OPTIMIZER_DIR`.

macOS lists the background item under System Settings > Login Items as **demo-video-optimizer** from
an unidentified developer. That is expected: it is your own local script, not a signed app.

## How it works

A [launchd](https://www.launchd.info) agent with a `WatchPaths` entry on the input folder runs
`optimize-demo-video.sh` whenever the folder changes. The script waits for the dropped file to
finish writing, reads `settings.txt`, and calls ffmpeg with `setpts` for the speed change, an
optional `scale` filter, `h264_videotoolbox`/`hevc_videotoolbox` for hardware encoding, and
`+faststart` so the file streams immediately. A `mkdir`-based lock keeps overlapping events from
processing the same file twice.

## Uninstall

```bash
./uninstall.sh
```

Removes the agent and the script. Your recordings and settings are left in place.

## License

MIT
