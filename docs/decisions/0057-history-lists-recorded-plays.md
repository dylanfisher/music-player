# 0057. History lists the tracks with a recorded play

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0022](0022-stable-track-identity-and-play-timeline.md),
  [0033](0033-import-from-other-players.md)

## Context

History listed every track whose `plays` row had a Last Played time (0022). An import from
Swinsian or iTunes sets Last Played and adds no history rows (0033), so after an import History
listed nearly the whole library before the app had played anything. The owner wants History to
list only what was played, newest first, and to say so when nothing was.

## Decision

**A track is in History when it has a row in `history`**: a play this app recorded, or one a
synced Mac recorded and the merge copied (0038). The order is still Last Played, newest first.
An imported Last Played that is later than the latest recorded play moves the track up, since
the Last Played column shows that time and the order follows the column.

**`recorded_paths` lists the paths with a history row**, a schema part of its own. A play
recorded here or merged from a synced Mac adds its path, a merged move carries the mark to the
path it keeps, and building the part fills it from `history`. It is derived from `history`, so
rebuilding it discards nothing. History's query starts from it and sorts by Last Played. The
cost follows the tracks played, not the length of the log: 11.9 ms (p95) over 1M synthetic
plays and 42,964 played tracks, where listing every track with a Last Played took 14.8 ms.

**An empty History says "Nothing played yet"**, centered over the track table in the secondary
label color. A search that finds none of History's tracks leaves the table empty without it,
since something has played.

## Alternatives considered

- **`play_count > 0`** — rejected: imported plays add to the count, so an import still fills
  History.
- **Order by the latest `played_at` in `history`** — rejected: a `max` per track over the log
  is the cost 0022 avoided, and the order would disagree with the Last Played column.
- **Leave imports out of Last Played** — rejected: Last Played is a column and a smart rule
  field, and the import's value is what the other player knew.
- **"Nothing played yet" in the status bar** — rejected: the eye goes to the empty table, and
  the bar's "0 tracks" already says the list is empty.
- **An `EXISTS` on `history_path` for each track `plays_last_played` lists** — rejected: a
  lookup per track in an index of a million rows measured 50 to 55 ms (p95), over the 30 ms
  budget.
- **`SELECT DISTINCT path_id FROM history`** — rejected: it reads the whole index, 18 ms
  before the rest of the query.
- **A column on `plays` saying it has a history row** — rejected: changing the stats part's
  shape discards the owner's plays, ratings and playlists.

## Consequences

The timeline and History now agree on what was played: History is the timeline's tracks, one
row each. Imported stats still show in the Play Count and Last Played columns and in smart
playlists.
