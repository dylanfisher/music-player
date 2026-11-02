# 0054. The status bar's totals, as Swinsian shows them

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0044](0044-status-bar-playlist-rename-playing-row.md)

## Context

The owner wants the status bar to read as Swinsian's: the list's totals centered, as "43400
tracks, 1048.1 GiB, 185 days 17 hours 29 minutes 26 seconds", the selection's after them in
parentheses, and a click on them to cycle what they show. The bar had only the track count, at
its leading edge.

## Decision

**Where the numbers come from.** The query that lists the table's track IDs also reads each
file's size and length frames, and the browser model keeps them beside the IDs in table order.
The list's totals are added up once per reload; the selection's are added up from the rows
selected each time the selection changes, which for a whole library selected is 43k additions.
The sort and search benchmarks time this query, since it's the one the window runs.

**How they read.** Sizes are in binary units to one decimal, up to GiB, as Swinsian's "1048.1
GiB" shows; under 1 KiB they're bytes. Lengths are rounded to the second, in days, hours,
minutes and seconds, leaving out the units that are zero. The track count keeps the app's one
spelling of a count, with a grouping separator ("43,400 tracks"). The playlist, discard and
health notes still follow after a " · ".

**What a click shows.** The list's with the selection's, the list's only, or the selection's
only, in that cycle; with nothing selected each shows the list's. The choice is app state,
`window.statusTotals` in `state.json`, beside the bar's visibility. The timeline still counts
plays and nothing else, since its rows are plays without one file each.

**Centered.** The totals sit in the bar's center gravity area, between the scan progress at the
leading edge and the problems button at the trailing edge, so they're centered while neither
shows and move aside when one does rather than overlapping it.

**Glass.** The bar sits on an `NSGlassEffectView` from macOS 26, square-cornered since it spans
the window's width, and on an `NSVisualEffectView` with the title bar's material before that.
The glass is what shows and hides with View ▸ Show Status Bar.

A failure shown in the bar stays until the next update of the bar, and a change of the
selection is one now.

## Alternatives considered

- **Summing in SQL for each selection** — rejected: a selection is a set of rows, not a
  filter, and binding up to 43k IDs per click costs more than adding numbers already in memory.
- **A second query for the sizes and lengths** — rejected: it would sort the whole list a
  second time on every reload.
- **`ByteCountFormatter`** — rejected: it writes decimal "GB", or "TB" past 1000, where the
  owner asked for Swinsian's GiB.
- **The selection's totals replacing the list's when rows are selected** — that's one of the
  three choices, not the default; the owner's example shows both.

## Consequences

The listing query returns three more columns per row, about 1 MB more for 43k tracks. A failure
message in the bar is replaced as soon as the selection changes.
