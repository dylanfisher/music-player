# 0048. Like and Dislike are one opinion per track

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0031](0031-album-artist-and-metadata-columns.md),
  [0038](0038-sync-logs.md)

## Context

The track context menu gets Swinsian's Like and Dislike (plan row 25.2). Like is the loved flag
that already exists: imports bring it, a smart rule matches it and the Loved column shows it.
Dislike is new. A track the user likes can't also be disliked, so the two are one value with
three states: liked, disliked, or neither.

## Decision

- **Disliked tracks are a table of their own in a schema part of their own, `disliked`**, keyed
  by path ID like `loved`. Changing the `loved` table's SQL to hold three states would rebuild
  that part and discard every loved track, the owner's Swinsian loves among them. Code keeps
  the two tables exclusive: `setOpinion` clears both before it writes one.
- **Like and Dislike toggle**, as Love or Unlove did: each gives the selection that opinion, or
  clears it when every selected track has it already. Liking a disliked track drops the dislike.
- **The sync field `loved` is the whole opinion.** The `loved` event keeps its shape and
  means liked (`true`) or neither (`false`); a new `disliked` event, with only `path`, means
  disliked. Both stamp the one field, so the latest of them wins and two machines can't end
  with a like and a dislike. Logs written before this read as they did.
- **An import's love doesn't replace a dislike**, as it doesn't replace a love: it only fills a
  track with no opinion.

## Rejected

- **A second sync field for disliked**, logged beside `loved` on every change. Each field merges
  on its own clock, so a like on one machine and a dislike on another could both win.
- **Showing disliked in the Loved column or a column of its own.** Not asked for; the menu's
  Like and Dislike are what set it.
