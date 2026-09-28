---
title: Troubleshooting
description: Run shrinkit doctor first, then common symptoms and what shrinkit's messages mean.
---

## Run shrinkit doctor first

```bash
shrinkit doctor
```

`shrinkit doctor` only reads; it changes nothing. It checks the command, ffmpeg, the working
folder, the watcher, the right-click entries, `settings.conf`, the presets and `input/`. It prints
one line per check, `ok`, `warn` or `FAIL`, with the rest of what it found under anything that is
not `ok`, and a fix where there is one. It exits non-zero when a check fails.

## Symptoms

- **Nothing happens after a drop.** Run `shrinkit doctor` and read its `watcher` and `input` lines.
- **A file stays in `input/` and is tried again on every run.** It could not be shrunk, and the
  reason is in `.logs/optimizer.log`. Move it out of `input/`.
- **The result has no sound.** `remove_audio = true` is the default. Run
  `shrinkit config remove_audio false`, or pass `--no-remove-audio` for one run.
- **No banners.** Check `notify` and `notify_start` with `shrinkit config`; see
  [Banners](/docs/settings/#banners).

## Messages

| Message | What to do |
| --- | --- |
| `ffmpeg is not on PATH or in the Homebrew folders` | `brew install ffmpeg`. |
| `Cannot create or write to the working folder` | Connect the drive it is on and run `shrinkit setup`, or pick another with `shrinkit config folder <path>`. |
| `macOS refused to start the watcher` | Read launchctl's reason above it. If shrinkit is switched off in System Settings > General > Login Items & Extensions, switch it on, then run `shrinkit setup`. |
| `ONE-TIME STEP: ... privacy-protected location` | Follow the steps it prints to grant Full Disk Access. |
| `'shrinkit' on your PATH is ...` | Two installs are in play. Run `shrinkit setup` from the one to keep. |
| `the preset '...' sets nothing` | Take the `#` off the lines that should count. |
| `... returned at once with the file as it was` | Put the editor's wait flag in `VISUAL` or `EDITOR`, such as `code --wait`. |
| `... was saved as rich text` | In TextEdit, Format > Make Plain Text, save, and run it again. |
| `shrinkit: run could not open a Terminal window` | Run the `shrinkit run` command it names. |

## The log

Every run writes to `.logs/optimizer.log` in the working folder: what it encoded, what it skipped
and why, and ffmpeg's own output.
