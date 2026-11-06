# 0105. Listening Stats: clicks narrow its table, and each import's last play has a date

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0102](0102-listening-stats.md) (what a click does, which plays have dates),
  [0033](0033-import-from-other-players.md) (an import keeps its last played apart)

## Context

Part 44c. The owner's answers after trying phase 43: a click in Stats should narrow the track
table under the panel instead of leaving Stats, and each Swinsian track's last-played date
should count as one dated play. Swinsian keeps no date per play, only a count and the last
played per track; phase 43 counted every imported play as undated, so a period's figures held
only this app's 122 plays while the owner's Swinsian library holds 43,293 over 11,202 tracks.

The index didn't keep the import's own date. An import sets `plays.last_played_seconds` to the
later of ours and theirs, and a play here sets it again; in the owner's library 70 of the
imported tracks have been played here since. Phase 43's plan records that a change to the stats
part's SQL discards the history, and a change to the imports part's SQL would drop
`imported_plays`, the baseline that keeps a second import from adding every play again. The
owner can't recover that baseline by importing again: the import would count everything twice.

## Decision

### Clicks narrow the table

- A row of Top Artists, Albums, Genres or Tracks, or of First Played, keeps Stats on screen and
  narrows its table to that row's tracks played in the period: `TrackFilter.stats`, a
  `StatsFilter` of the row's list and ID (a track's path ID), with the row's name. The artist is
  the Artists column's, as the lists group it. A track's row lists it alone and selects it.
- **A bar** narrows the table to the tracks played in its span, in Stats, the same way. The
  owner's answer was about any click in Stats, and showing the timeline left it. A double-click
  on a bar still shows its plays on the timeline (`plays:<start>-<end>`), so the timeline of a
  span stays a click away. Year in Review's rows and months act on the main window's Stats for
  that year.
- **What shows it:** the row or bar is marked in its card, more strongly than the hover, and the
  panel's header shows a button with the row's name or the bar's span and a clear mark; it
  lists every track of the period again, and so does a click on the marked row. The header is
  where Stats' other controls are and shows only while Stats does. The status bar was the other
  place: its text is the list's totals for every source, and a control there would be a new kind
  of item for the status bar builder (ADR 0085, 0089) for one source.
- **How long it lasts:** another period keeps a row's filter, so the album's plays this year
  follow its plays this month, and drops a bar's, whose span is in one period. Any other source
  drops it. Back and Forward keep it with the rest of the window's place. It isn't saved: the
  state file's source is `stats:<period>` as before, and no key in it or the config changes.
- **Hidden columns:** showing Stats selects All in the browser columns, as Library Health does
  (ADR 0099), since their selections would narrow the table with nothing on screen saying why.

### Each import's last play is a dated play

- **Stored apart.** A schema part of its own, `importedLastPlays`, holds
  `imported_last_plays (path_id, player, played_at)`: each player's last play of a path, in
  whole seconds, as its imports gave it. Adding a part rebuilds nothing else; every other part's
  SQL is unchanged.
- **Filled when it's made.** The part's SQL fills it from what's there: a path's Last Played,
  where one player's import alone counted plays for it and no history row is at or after that
  time. A history row at or after it means Last Played is that real play's time, or a later
  one's, so the import's own date is lost there; taking it would date a real play twice. Where
  two players counted plays, Last Played could be either's. For the owner's library this fills
  11,102 of 11,172 tracks. Importing the Swinsian library again records the other 70: it adds no
  plays, since the counts match the baseline, and the preview says how many last plays it dates.
- **Kept by imports and sync.** An import records the source's last played for each track it
  counted plays for, the later of it and the one recorded. A counts event in the sync log
  carries it, now whenever the import records one, not only when it beat this Mac's Last
  Played, and a Mac that reads the event records it too. A path merged into another takes its
  last plays, unless the other has one for the same player; a deleted path's go with it.
- **Counted.** A recorded last play counts only while that player's import counted at least one
  play for the path, since it is one of those plays. Each period's report, the table under it,
  every album's and artist's first play and the year menu read the history and these last plays
  alike: one union of the two per scan. All Time's undated plays are the counted plays less
  both. The totals say how many of the period's plays came from an import ("40 plays from an
  import", and the Plays figure's tooltip says what that is), as do the command line's text and
  JSON (`importedPlays`).
- **No double count against the history.** Once stored apart, the import's date is never a
  real play's: a play here or on a synced Mac adds a history row and one to `play_count`, and the
  import's count was the other player's alone. So a history row near an imported last play is a
  second play, counted twice in `play_count` already, and both keep their dates. The one place
  the two meet is the fill above, which reads Last Played and so skips any path with a history
  row at or after it.

## Alternatives considered

- **A column in `imported_plays`.** Rejected: the part's SQL would change, the part would be
  rebuilt, and the baseline lost; the next import would add the owner's 43,293 plays again.
- **Reading `plays.last_played_seconds` at each report.** Rejected: a play here moves it on, so
  the import's date would vanish from Stats the first time the track played here.
- **Skipping an imported last play with a history row within the track's length of it.**
  Rejected: nothing records one listening in both players, and it costs a lookup into the
  history per imported track on every report, 0.7 s over 1M plays.
- **Spreading the undated plays over the dates between added and last played.** Rejected: it
  invents dates, which ADR 0033 refused for the timeline.
- **Bars still going to the timeline.** Rejected as the click: it leaves Stats, which the owner
  asked clicks not to do. Kept as the double-click.
- **The filter as a status bar item.** Rejected, above.

## Consequences

The owner's All Time gains about 11,100 plays with dates back to February 2022, This Year
about 4,900 and 2025 about 3,300; the year menu starts at 2022. The undated count stays large:
the owner's `play_count` adds up to 86,787, about twice the 43,293 Swinsian counted plus the
122 played here, which this part doesn't change. Bench's played library now imports a last
play for each of its 43,000 tracks; the stats rows stay within budget. A future change to the
last plays part's SQL loses them, which an import of the same library brings back for that
player's own library, and the sync log for the others.
