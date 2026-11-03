# 0068. A click in the Rating column rates the track

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The owner, 2026-11-02: "you should be able to click and adjust rating directly within the table
cell if the rating column is visible, in addition to the existing right click menu". The Rating
column draws a track's stars as text, filled stars only, so an unrated track's cell is empty.

## Decision

- **A plain click sets the rating to the star under the pointer**, counted from the left of the
  cell's text in the table's font, up to five. The click also selects the row as any click
  does; the rating goes to the clicked track only, not the rest of a selection.
- **A click left of the first star, or on the last star of the rating the track has, clears
  it.** The empty stars don't show, so there's nothing else to aim at to clear a rating.
- **A click with ⌘, ⇧, ⌥ or ⌃ only selects**, so extending a selection over the column never
  rates. The rating is written as Rating ▸ writes it: through the index, synced, and the table
  refreshes.

## Alternatives considered

- **Drawing hollow stars for the empty ones** — rejected for now: every row of the column would
  draw five glyphs, and Swinsian and Music show nothing for an unrated track.
- **Rating the whole selection** — rejected: the click selects its row first, so a selection
  that includes another row can't survive the click without a modifier.
