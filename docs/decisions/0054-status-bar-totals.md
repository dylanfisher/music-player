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

**Where the numbers come from.** The reader keeps every track's file size and length by ID,
read in one query on first use and again once any connection has changed the index, which
SQLite's `data_version` and `total_changes()` tell. The list's totals add up the listed IDs
after each reload, and the selection's the selected IDs after each change of the selection,
both on the reader and after the rows show, so the totals never hold up the table. A playlist
that lists a track twice counts it twice. The sort and search benchmarks time the IDs and their
totals together, since the window runs both.

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

**Material.** The bar sits on an `NSVisualEffectView` with the `headerView` material, the one
AppKit names for table headers, on every macOS version, so it is the same translucent gray as
the track table's header. It is as tall as that header, read from the header view rather than
written down, so it follows the header's height on macOS 12 and 26 alike, and its text is the
lists' 11-point font, centered top to bottom. The material view is what shows and hides with
View ▸ Show Status Bar. (Phase 29.3 replaced the macOS 26 glass and the title bar's material,
which the owner found didn't match the headers.)

A failure shown in the bar stays until the next update of the bar, and a change of the
selection is one now. Totals that arrive after a message showed are kept for the next update
and leave the message in place.

## Alternatives considered

- **Summing in SQL for each selection** — rejected: a selection is a set of rows, not a
  filter, and binding up to 43k IDs per click costs more than adding numbers already in memory.
- **Reading each file's size and length in the query that lists the IDs** — rejected: the
  wider rows made every search and sort sort more, about 45% slower per search keystroke and
  16% per sort, and the launch to the first rows 30% slower.
- **A `count`/`sum` query with the list's filter** — rejected: it runs the filter and the
  joins a second time, which cost more than the wider rows.
- **`ByteCountFormatter`** — rejected: it writes decimal "GB", or "TB" past 1000, where the
  owner asked for Swinsian's GiB. The table's Size column keeps the system's formatter, so the
  bar and the column disagree for the same file, as "303.5 MiB" beside "318 MB"; the bar
  follows Swinsian and the column follows the Finder, on purpose.
- **The selection's totals replacing the list's when rows are selected** — that's one of the
  three choices, not the default; the owner's example shows both.

## Consequences

The reader holds a map of every track's size and length, about 2 MB for 43k tracks, and reads
it again, about 60 ms, after each change to the index, such as each batch a scan commits. The
totals show a moment after the rows. A failure message in the bar is replaced once the
selection changes.
