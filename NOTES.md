# Notes

Working notes on why parts of shrinkit are the way they are. Nothing here is needed to use the
tool; it is here so the reasoning is not lost and not re-litigated.

## Quality-based encoding, not a fixed bitrate

An early version encoded at a fixed bitrate and, on a real screen capture, produced a file larger
than the source. Screen recordings are mostly static, so a bitrate floor spends bits on frames that
have nothing in them. CRF spends what the picture actually needs.

## Software encoding, not videotoolbox

`h264_videotoolbox` looks like the obvious choice on Apple silicon and is not. It is rate-based
rather than quality-based, and on a 45 second 4K sample it gave 2 878 KB against 919 KB from
`libx264 -crf 28`, while taking 6.7 seconds against 4.6. Slower and three times bigger, so the
software encoder stays.

## The lock is keyed on liveness, not on a timeout

The first version treated a lock older than thirty minutes as abandoned. That is wrong in both
directions: a queue of large files runs past thirty minutes and gets its lock stolen mid-encode,
while a lock from a killed run blocks everything for half an hour.

A background process refreshing a timestamp fixed the first half and introduced something worse.
The `sleep` inside it survived the parent, held the inherited pipe open, and hung anything reading
the script's output.

Now the lock holds the owner's pid and `kill -0` decides. A live owner is never overruled however
long it takes, and a dead one frees the lock at once.

## Settings are key = value, not JSON

The config was JSON with comments, which meant shelling out to `osascript -l JavaScript` on every
single run just to read fifteen keys, and meant one stray comma silently reset every setting to its
default. Plain `key = value` parses in about ten lines of zsh, keeps comments for free, and lets
`shrinkit config <key> <value>` rewrite one line without disturbing the rest of the file.

## The notification icon cannot be changed

Banners are posted with `osascript`, and macOS pins the icon to Script Editor's. Only the title and
the sound can be set. Changing the icon needs a real signed application bundle, which is a much
larger step than this tool is worth so far, and would be the point at which Swift starts to make
sense over zsh.

## Trimming and audio cannot both happen

`mpdecimate` drops video frames. The audio track does not shorten with them, so the two would drift
apart immediately. When a file is set to keep its audio, trimming stands down for that file and
says so in the log.

## shellcheck does not apply here

Every script is `#!/bin/zsh` and shellcheck parses only sh, bash, dash and ksh. `shfmt` does handle
zsh and takes its style from `.editorconfig`, so that plus the test suite is what CI runs.

## Homebrew cannot run the watcher

Homebrew's service DSL covers `run`, `run_type`, `interval`, `cron` and `keep_alive`, but has no
`WatchPaths`. A formula can therefore install the command line half of shrinkit but not the folder
watcher, which will need a `shrinkit setup` subcommand of its own.
