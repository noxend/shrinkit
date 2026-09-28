# shrinkit

[![tests](https://github.com/noxend/shrinkit/actions/workflows/tests.yml/badge.svg)](https://github.com/noxend/shrinkit/actions/workflows/tests.yml)

shrinkit compresses macOS screen recordings and speeds them up. Drop a `.mov` into a folder, or
right-click it in Finder, and a smaller `.mp4` comes back. It can also cut stretches out of a
recording and join several recordings into one. The encoding is ffmpeg.

**Documentation: [noxend.github.io/shrinkit](https://noxend.github.io/shrinkit/)**

## Install

Needs macOS and [Homebrew](https://brew.sh). ffmpeg comes along with it.

```bash
brew tap noxend/shrinkit https://github.com/noxend/shrinkit
brew install --cask noxend/shrinkit/shrnkit
```

The first command adds this repository as a tap, and Homebrew installs and updates shrinkit from
there. The command it installs is `shrinkit`.

## Use

- **Right-click a recording** in Finder and pick `shrinkit: 2x`, `shrinkit: sharp` or
  `shrinkit: tiny`. The result lands beside it.
  [More](https://noxend.github.io/shrinkit/docs/right-click/)
- **Drop a recording** into `input/` through the shortcut on your Desktop. The result is in
  `output/`. [More](https://noxend.github.io/shrinkit/docs/watch-folder/)
- **From a terminal**, name the file. Any setting works as a one-off flag:
  `shrinkit --speed 4 recording.mov`. [More](https://noxend.github.io/shrinkit/docs/command-line/)
- **Cut a stretch out, or edit several recordings at once**, each with its own preset and cuts,
  joined if you want: `shrinkit --cut 0:32-0:35 recording.mov`, or right-click the recordings and
  pick `shrinkit: edit`. [More](https://noxend.github.io/shrinkit/docs/edit/)

If something does not work, run `shrinkit doctor`. It checks the install without changing anything,
says what is wrong, and what to run where there is a fix. [More](https://noxend.github.io/shrinkit/docs/troubleshooting/)

## Update and uninstall

```bash
brew upgrade --cask shrnkit
brew uninstall --cask shrnkit
```

Your recordings, results, settings and presets stay in the working folder.
[More](https://noxend.github.io/shrinkit/docs/install/#uninstalling)

## Working on shrinkit

```bash
git clone https://github.com/noxend/shrinkit.git
cd shrinkit
./shrinkit.sh setup        # install from this checkout
./shrinkit.sh teardown     # undo it
./tests/run-tests.sh       # the test suite
```

A clone in `~/Desktop`, `~/Documents` or `~/Downloads` is copied to `~/.local` on setup, because
macOS does not let the watcher read those folders, so run `setup` again after a `git pull` there.

The documentation site is in [`docs/`](docs/): one Markdown file per page in `docs/content/docs/`.
It is published with each release.

## License

MIT
