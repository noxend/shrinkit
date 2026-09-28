---
title: Right-click in Finder
description: Shrink a recording where it is, from Finder.
---

`shrinkit setup` adds these entries to Finder's right-click menu, as Quick Actions in
`~/Library/Services`:

| Entry | Offered for | What it does |
| --- | --- | --- |
| `shrinkit: <preset>` | movie files | Shrinks with that [preset](/docs/presets/). One entry per `.conf` file in `presets/`; run `shrinkit preset sync` after adding one by hand. |
| `shrinkit: edit` | movie files | Writes an [edit file](/docs/edit/) for up to 10 recordings. |
| `shrinkit: run` | plain text files | Runs an edit file in a Terminal window. |
| `shrinkit: merge` | movie files | [Joins](/docs/merge/) 2 to 10 recordings. |

## A preset's entry

Select one or more recordings and pick, for example, `shrinkit: sharp`. Each recording is shrunk in
turn with that preset, and the result lands beside it. The recording stays where it was. A selected
file that is not a `.mov`, `.mp4` or `.m4v` is skipped.

It runs the same as:

```bash
shrinkit --preset sharp clip.mov
```

A right-click run reports through [banners](/docs/settings/#banners), and writes the details to
`.logs/optimizer.log` in the working folder.

## Result names

A result is always an `.mp4` named after the recording and the preset: `clip-sharp.mp4` for
`clip.mov` shrunk with `sharp`, and `clip.mp4` with no preset.

A result never replaces a file. When the name is taken, a Unix timestamp is added:
`clip-1759000000.mp4`. If that is taken too, the process id is added after it.
