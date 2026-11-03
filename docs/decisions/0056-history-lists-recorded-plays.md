# 0056. History lists the tracks with a recorded play

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

The query keeps starting from `plays_last_played`, as 0022 chose, and adds an `EXISTS` on
`history_path` for each played track. The cost still follows the tracks played, not the length
of the log.

## Alternatives considered

- **`play_count > 0`** — rejected: imported plays add to the count, so an import still fills
  History.
- **Order by the latest `played_at` in `history`** — rejected: a `max` per track over the log
  is the cost 0022 avoided, and the order would disagree with the Last Played column.
- **Leave imports out of Last Played** — rejected: Last Played is a column and a smart rule
  field, and the import's value is what the other player knew.

## Consequences

The timeline and History now agree on what was played: History is the timeline's tracks, one
row each. Imported stats still show in the Play Count and Last Played columns and in smart
playlists.
