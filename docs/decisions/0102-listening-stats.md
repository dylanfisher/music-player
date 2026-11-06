# 0102. Listening Stats: a sidebar source with a panel of its own height, read by scans

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0099](0099-library-health-panel.md) (a panel may have a height of its own),
  [0036](0036-scripting.md) (a command that replies)
- **Amended by:** [0105](0105-stats-clicks-filter-and-imported-last-plays.md): a click narrows
  the table under the panel, and each import's last play counts as a dated play.
  [0109](0109-listening-stats-rolling-periods.md): the last 7, 30 and 365 days replace the
  calendar's week, month and year, the totals fill their row beside Plays per Day, columns are
  300 points or more, and Save as Playlist asks for the name first.

## Context

Phase 43 (part 42f): the owner asked for Listening Stats as "an interesting visual panel, like
browse and library health", over a history that may reach 1,000,000 plays, on a 2015 MacBook
Pro. Only `history` rows have dates (ADR 0022); an import adds plays without them (ADR 0033).
Nothing indexes `played_at`. The owner's answers: imported plays aren't ranked in any period,
All Time counts them apart; the top lists rank by plays by default; Year in Review is part of
the phase; Stats is a sidebar source.

## Decision

- **A source.** `BrowserSource.stats(period)`, saved as `stats:week`, `stats:month`,
  `stats:year`, `stats:<year>` or `stats:all`, is the Stats row after Timeline in the
  sidebar's Library group. The row shows the period it showed last. The track table below
  lists the tracks played in the period, sorted by Plays until the user sorts otherwise.
- **Periods** come from `Calendar.current`: its time zone and its first weekday. This Week,
  This Month and This Year hold the moment of reading; a chosen year is a whole year; All
  Time has no bounds.
- **What a report holds.** Plays, approximate hours (each play counts its track's whole
  length, or the last length read of a path no longer in the library), distinct tracks,
  artists and albums, the share of the library's tracks played, the plays not in the
  library, and for All Time the plays without dates (`sum(plays.play_count)` less the
  history rows), shown as "+N imported plays without dates, not ranked". Top 25 artists
  (as the Artists column groups them), albums, tracks and genres by plays and by hours; the
  plays of paths no longer in the library are one dimmed "Not in the library" row in each
  list, and a row of their own, by title, in Top Tracks. Bars by day (a range up to a month),
  week (up to a year), month (up to ten years) or year, cut to the period; the calendar's
  months, for the busiest month; the busiest day; a weekday × hour grid; the albums and
  artists whose first dated play is in the period; plays by codec and by rate group: CD
  quality (lossless at 48 kHz or less), hi-res PCM, DSD and lossy (AAC, MP3), a fourth group
  since a 44.1 kHz MP3 isn't CD quality.
- **Local time.** SQLite groups the period's plays into hour buckets, or quarter hours in a
  zone whose offsets aren't whole hours (India's). Each bucket's day, weekday and hour come
  from the zone's offset at that time, looked up again only past the next transition, so a
  daylight saving day has 23 or 25 hours and a play at 23:59 and one at 00:01 fall on two
  days. Bars are `Calendar` intervals; a bucket never straddles a local midnight.
- **Reads.** `StatsReader`, an actor on a read-only connection of its own opened the first
  time Stats shows, runs two scans per report: plays per path (joined to `tracks` and `paths`)
  and plays per bucket, both `NOT INDEXED`, since SQLite's own plan walks `history_path` and
  looks up every row, 0.7 s for a week of 1M plays against 16 ms. Every album's and artist's
  first play is one more scan, kept until `PRAGMA data_version` shows another connection
  wrote. The report is built in Swift; each list keeps its top 25 in one pass. A report read
  after a newer one started is dropped.
- **No index on `history (played_at, path_id)`.** Measured over 1M synthetic plays on Apple
  Silicon: with it the week and month take 2 ms instead of 26, a year 35 instead of 57;
  opening (every first play) and All Time read every row either way and don't change; it
  adds 16 MB. Every period is within its budget without it. Were it needed, it would be a
  schema part of its own: a change to the stats part's SQL rebuilds the stats and discards
  the history.
- **The panel** takes the slot of ADR 0099, with a header (Listening Stats, the period's
  segments and year menu, Plays or Hours, Year in Review) over cards that flow into columns
  of 270 points or more and scroll: totals, plays over time, When You Listen, the four top
  lists, First Played (albums or artists), Formats. Everything is drawn in AppKit; there is
  no chart framework on macOS 12. The cards are made once and refilled, so a hover or a
  list's scroll survives a new report.
- **Its own height.** While Stats shows the slot is `window.statsHeight` tall (380 by
  default), an added state key, saved when the user drags it; the columns and the health
  panel keep `window.browserHeight`. Changing panels moves the divider only when the heights
  differ, and the divider's own moves aren't saved as the user's.
- **Clicks.** A top artist or album shows the whole library at its first track, as Go to
  Item does (ADR 0046); a genre filters to it, as the palette's does; a track is selected in
  the table below; a bar shows its span's plays in the timeline, the source `plays:<start>-
  <end>`, which selects no sidebar row and puts the span in the status bar; Back returns to
  Stats. Each list's button saves a manual playlist of the tracks still in the library that
  its rows were played through, in its order, named "Top Artists, Nov 1 – 30, 2026",
  "…, 2025" or "…, All Time", and shows it. Stats writes nothing else.
- **Year in Review is a window of its own**, opened from the header for This Year or a chosen
  year, or by its command (the year Stats shows, else this one): the year in large type, its
  totals, highlights (busiest month and day, new albums and artists), plays per month with the
  busiest marked, the top ten of each list, first played, the clock and the formats, from
  the year's report and the same cards; its clicks act in the main window.
- **Commands.** Show Listening Stats (`library.stats`, its argument a period) and Show Year in
  Review are in the File menu after Show Library Health, so in the palette. A command marked
  `replies` answers the command line through a `report` request: `music-player stats
  [--period <period>] [--json]` shows Stats and prints the totals and the top ten of each
  list, or the report as JSON. `--period` goes only with `stats`, `--json` with `status` and
  `stats`. A link can't ask for a report.

## Alternatives considered

- **The full content area for Stats.** Rejected: the track table under the panel is what a
  bar or row narrows to, and the owner asked for the panel shape.
- **The columns' height for Stats too (as ADR 0099 chose for health).** Rejected: 160 points
  shows one row of cards, and dragging Stats taller would leave the columns that tall.
- **Swift Charts.** Needs macOS 13.
- **Year in Review as a mode of the panel.** Rejected: a year's page reads top to bottom at a
  width of its own, beside the table, not inside a slot the user keeps short.
- **Days in SQL with `'localtime'`.** Rejected: SQLite's local time is the process's, which
  tests can't set, and it can't take the calendar's first weekday.
- **Skip counts by period.** Deferred: skips have no dates and this phase adds no table.

## Consequences

Opening Stats costs a scan of the whole history for the first plays (about 0.3 s per 1M
plays on Apple Silicon), then a period costs two scans of it. A history far past 1M rows, or
an old Mac over budget at the checkpoint, is when the index above becomes the fix.
