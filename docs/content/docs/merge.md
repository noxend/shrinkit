---
title: Merge
description: Join several recordings into one.
---

Select 2 to 10 recordings, right-click, and pick `shrinkit: merge`. From a terminal:

```bash
shrinkit merge take1.mov take2.mov take3.mov
```

The result is `<first>-merged` beside the first recording in join order. When that name is taken, a
Unix timestamp is added, and then the process id. The originals stay where they are.

## Order

Names that start with a number of up to three digits followed by a space, such as `1 intro.mov`,
or that are only that number, such as `2.mov`, come first, in number order. The rest follow in the
order they were recorded, by the creation time the file states, else by the file's dates. A date at
the start of a name, such as `12-01-2026 demo.mov`, is not read as a number.

The order you select or type the files in does not set the join order; it only breaks a tie. To set
the order, number the names, or use an [edit file](/docs/edit/#where-results-go) with
`merge = true`, which joins in block order.

## How it joins

Recordings that match are joined without re-encoding, into the first one's container, unless that
copy fails or comes out the wrong length. Otherwise they are re-encoded to `.mp4`.

Merging does not shrink. Run a [preset](/docs/presets/) on the result, or use `merge = true` in an
edit file to shrink and join in one go.

It posts [banners](/docs/settings/#banners).
