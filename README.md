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

## Requirements

- macOS
- [ffmpeg](https://ffmpeg.org). `setup` offers to fetch it with [Homebrew](https://brew.sh) if you
  do not have it.

## Install

```bash
git clone https://github.com/noxend/shrinkit.git
cd shrinkit
./shrinkit.sh setup
```

`setup` creates the working folders under `~/Movies/shrinkit`, registers a launchd agent that
watches `input/`, builds the right-click entries, and puts a `shrinkit` shortcut on your Desktop
and a `shrinkit` command on your PATH. Run it again any time; it never overwrites your settings.
`./install.sh` still works and does exactly this.

For a different working folder:

```bash
SHRINKIT_DIR="$HOME/Movies/clips" ./shrinkit.sh setup
```

The agent runs the checkout you set up from, rather than a copy of it, so `git pull` is picked up
with nothing to reinstall. The price is that the checkout has to stay where it is: move or delete
it and dropping a recording into `input/` quietly does nothing, because the agent has nothing left
to run. Run `setup` again from the new location to fix that.

A clone inside `~/Desktop`, `~/Documents` or `~/Downloads` is the exception. macOS guards those
three, and neither the background agent nor a right-click entry can read a file in one, so `setup`
copies the tool to `~/.local` instead of pointing at the clone and says so. Everything works the
same afterwards, except that `git pull` no longer reaches the copy: run `setup` again after one.

`~/Desktop`, `~/Documents` and `~/Downloads` are guarded by macOS privacy protection, and a
background job is refused there until you grant it Full Disk Access by hand. If you install into
one of them `setup` prints the steps. Anywhere else, `~/Movies` included, needs nothing.

## Use

1. Open the `shrinkit` shortcut on your Desktop and drop a recording into `input/`. QuickTime
   `.mov`, `.mp4` and `.m4v` all work.
2. Give it a few seconds.
3. Collect the result from `output/`, converted to `.mp4` and named `clip.mp4`.

The original goes to a hidden `.processed/` folder, so the working folder holds only
`settings.conf`, `presets/`, `input/` and `output/`.

## Right-click a video

Most of the right-click menu is the list of your presets. Every file in `presets/` gets an entry
named after it, so out of the box you get `shrinkit: 2x`, the everyday one, `shrinkit: sharp`,
sharper than the default for something like a PR, and `shrinkit: tiny`, as small as it gets. The
result is named after the preset that ran, `clip-2x.mp4`, `clip-sharp.mp4` or `clip-tiny.mp4`, and
lands beside the original, which stays where it is. You can select several files to do them
together.

Add a preset and it becomes a new entry; `setup` rebuilds the menu from `presets/` every time it
runs. Two entries aren't presets: `shrinkit: mark cuts`, for marking a stretch to remove
before shrinking, and `shrinkit: merge`, for joining several recordings into one. Both are below.

## One-off changes on the command line

Every setting doubles as a flag, so one file can be handled differently without editing anything:

```bash
shrinkit --speed 4 --crf 32 recording.mov
shrinkit --no-remove-audio recording.mov
```

A true/false setting takes no value: `--remove-audio` turns it on and `--no-remove-audio` turns it
off. Name no files and the flags apply to whatever is sitting in `input/`. Flags beat the config
file.

Two flags are not settings: `--cut` takes a range to remove from the recording and `--keep` takes
the footage to leave in. Both need the file named. See below.

## Cutting a stretch out of the middle

From the command line, name the ranges with `--cut`, once each:

```bash
shrinkit --cut 0:32-0:35 --cut 2:30-end recording.mov
```

When it is easier to say what stays than what goes, `--keep` is the same edit from the other side:
it names the footage to survive, and everything outside those ranges is cut.

```bash
shrinkit --keep 1:00-2:00 recording.mov
```

One command line takes one or the other, not both. Everything else in this section holds for both:
the same time formats, the same `end` and `0`, the same replacement of the sidecar. A `--keep` that
covers the whole recording leaves it whole and says so, rather than reporting a cut that never
happened. The sidecar stays a list of cuts either way; there is no keep file.

That is the whole feature for a one-off. The rest of this section is the other way in, a file you
edit next to the recording, which is what the right-click menu uses and what survives being closed
and come back to.

Right-click a recording and choose `shrinkit: mark cuts`. It opens the recording, so you can find
the moment, and a `<recording>.cuts` text file next to it (creating one the first time) where you
mark what to remove, one range per line:

```
# clip.mov.cuts
0-0:20
0:32-0:35
1:10-1:12.5
2:30-end
```

Save it, then process the recording as usual: drop it into `input/` or right-click it and pick a
preset. Each range is removed entirely, not just skipped past on playback, since the frames are
never written to the output at all. Good for cutting a secret out of a recording, a password typed
into a form, a private chat glanced at mid-recording, and works just as well for plain shortening.

`end` reaches the real length of the clip without you having to know it, so trimming the end is the
same `.cuts` line as everything else, not a separate mechanism: `2:30-end` cuts from 2:30 on. `0` is
already the start, so trimming the beginning needs nothing special: `0-0:20` cuts the first 20
seconds.

Times are `M:SS`, `M:SS.f`, or plain seconds, in the file and in `--cut` or `--keep` alike. `#`
starts a comment, a range under a tenth of a second is too short to reliably land on a real frame,
a range starting at or past the clip's real length selects nothing at all and is skipped rather
than silently doing nothing while claiming success, and a line that does not parse is skipped
rather than stopping the run. Two `--keep` ranges closer together than a tenth of a second are
joined for the same reason: the cut between them would land on no frame. All of these are logged,
so check the log if a cut you expected does not show up in the result. If you edit the file in
TextEdit rather than through the menu entry, save it as plain text (Format > Make Plain Text) with
Smart Dashes off (Edit > Substitutions), or it will not parse as written.

`--cut` and `--keep` replace the sidecar for that run rather than adding to it, the same way every
other flag beats the config file, and say so in the log when there was one to ignore. Unlike the
other flags they need the recording named on the same command line: a timestamp only means
something in one particular file, so applying one to whatever happens to be sitting in `input/` is
never what you meant. Name several files and the same ranges apply to all of them, sidecars
included, so that is worth a second look before you do it.

Cutting needs a steady frame rate to land exactly where it is told to, so a recording gets
resampled to `fps` (30 if `fps = 0`) before anything is removed, even when `fps = 0` would
otherwise mean "keep the original" for the rest of the recording.

Dropping a recording into `input/` files the `.cuts` sidecar away with the original once
processing is done. Right-clicking a file directly leaves both in place, the same way it leaves
the recording itself in place. Once you have the result, check it and clean up the source
yourself.

## Joining several recordings into one

A demo recorded in two takes, or a bug that takes a couple of clips to show, goes together in one
step. Select the recordings in Finder, right-click, and pick `shrinkit: merge`. The joined file
lands beside the first clip and is named after it, `<first clip>-merged.mov`, and the recordings
themselves stay where they are.

```bash
shrinkit merge "1 intro.mov" "2 bug.mov"
```

Merging does not shrink. What comes out is an ordinary recording, so run a preset on it afterwards
or drop it into `input/`, the same as anything else.

The takes are joined in the order they were shot: a screen recording carries the moment it started
inside it, so nothing has to be renamed or arranged for that to come out right. For a different
order, number the names, `1 intro.mov`, `2 bug.mov`, `3 fix.mov`. Numbered takes lead, by their
number, and anything left unnumbered follows in the order it was recorded.

The number has to be followed by a space, or be the whole name, `1.mov`. Any other separator
belongs to a date as readily as to a take, and `12-01-2026 demo.mov` taken for take 12 would join
a set backwards; left unnumbered it still lands in the place it was recorded in. Three digits is
the most a take number can have, so `2026 review.mov` is a name too.

Recordings that agree on size, codec and sound are joined without being re-encoded, which is quick,
leaves the picture exactly as the recorder made it, and keeps the first take's own extension. A
take carrying two sound tracks, system audio and a microphone, keeps both. Recordings that do not
agree are re-encoded to match instead and come out as `.mp4`: the smaller ones are padded into the
largest frame of the set, a take with no sound is given silence when another take has some, and a
take with two sound tracks is down to one. The log says which of the two ran.

## Presets

A preset is a file of the same settings in `presets/`, read on top of `settings.conf`. Whatever it
leaves out stays as the config has it, so a preset only spells out what it changes. The finished
file is named after the preset that made it, which is how you can tell two copies apart.

```bash
shrinkit --preset tiny recording.mov
```

Copy a preset file to make your own, then give it a menu entry without reinstalling:

```bash
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
| `keep_original` | `true` files the original in `.processed/`, `false` deletes it | `true` |
| `keep_days` | Delete originals from `.processed/` once this many days old, up to 3650; `0` keeps them forever | `0` |
| `notify` | Post a macOS banner when a file is done | `true` |
| `notify_sound` | `Glass`, `Ping`, `Pop`, `Hero` and the rest, or `none` | `Glass` |
| `notify_start` | Also post a quiet banner when a file starts | `true` |
| `copy_to_clipboard` | Put the finished file on the clipboard, ready to paste | `false` |

Logs go to a hidden `.logs/` folder. The watched folder is fixed when you install, because launchd
wants an absolute path; to move it, run `setup` again with `SHRINKIT_DIR`. To have results
land somewhere else, a synced folder for instance, replace `output/` with a symlink to it.

System Settings > Login Items will list `shrinkit` from an unidentified developer. That is your own
script rather than a signed application, so there is nothing to sign.

## Update and uninstall

```bash
git pull              # the agent runs your checkout, so there is nothing to reinstall
shrinkit teardown     # remove the agent, the PATH entry, the shortcut and the menu entries
```

Run `setup` again after a `git pull` only when the release notes say to, which means the agent or
the menu entries themselves changed. A clone in one of the three guarded folders always needs it,
since there the copy is what runs. Tearing down leaves your recordings and settings where they are.

Under Homebrew the order matters, because `brew` cannot run anything before it deletes the keg:

```bash
shrinkit teardown
brew uninstall shrinkit
```

The other way round leaves the agent and the five right-click entries pointing at a path that no
longer exists, and no `shrinkit` left to run `teardown` with. Every entry then fails silently. Put
it back and undo it in order:

```bash
brew install shrinkit && shrinkit teardown && brew uninstall shrinkit
```

Or by hand. Deleting the plist does not unload an agent that is already running, so the unload
comes first:

```bash
launchctl bootout "gui/$(id -u)/com.shrinkit"
rm -f ~/Library/LaunchAgents/com.shrinkit.plist ~/Desktop/shrinkit
rm -rf ~/Library/Services/shrinkit:*.workflow ~/.local/bin/shrinkit ~/.local/share/shrinkit
/System/Library/CoreServices/pbs -update
```

## License

MIT
