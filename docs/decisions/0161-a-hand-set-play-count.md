# 0161. A play count set by hand is an offset over the plays counted, the latest winning

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0038](0038-sync-logs.md) (a `playCount` event, last writer wins)
- **See also:** [0033](0033-import-from-other-players.md) (import totals in the count),
  [0022](0022-stable-track-identity-and-play-timeline.md) (stats keyed by path ID)

## Context

The owner asked to set a play count by hand, from Get Info, for one track or several. A play
count is app state, `plays.play_count` in the index, which plays here, plays synced from the
other Macs and each player's import totals add to; the app writes no play count to a file. The
count has to sync (ADR 0038) without a hand-set count being overwritten by the plays the
other Macs send, or counted twice.

Sync unions plays, each event once by its sequence number, and keeps each player's highest
import total. A count set to a value doesn't fit either: as a union of deltas, two Macs that
each set 10 over 5 would end at 15; as a value, the plays another Mac sends after it would
either replace it or be lost.

## Decision

- **An offset, stored.** Setting a track's count to N stores, in `play_count_offsets`, how far
  N sits from the plays counted for it (history, synced plays and import totals): N less that,
  below 0 for a count set lower. `plays.play_count` changes by the difference, so every reader
  of it, the table, sort, smart playlists and Listening Stats' undated plays, sees N with no
  change. The history keeps its rows: a hand-set count isn't dated plays.
- **Synced as the latest set.** The set logs `playCount` with `path` and `offset`, a field of
  `sync_items` (`SyncField.playCount`), so the latest clock wins, then the higher machine ID,
  as for a rating. Merging puts the event's offset over the plays the reading Mac counts. Once
  every log is read every Mac counts the same plays, so every Mac shows the same count.
- **Plays after it add on.** A play here or on another Mac adds to the count as it always did;
  the offset stays. Plays another Mac made before the set but sent after it add on too: the
  set covered only the plays the setting Mac had counted.
- **Two sets don't add up.** The later replaces the earlier everywhere.
- **Never shown below 0.** A Mac that reads a set before plays it was set over (a log it
  couldn't open this time) can hold a count below 0 until they arrive; the table and sort read
  `max(0, play_count)`.
- **A part of its own,** `playCounts`, so its shape changes without discarding the other
  stats, ordered after `imports`. Rebuilding it takes the offsets out of the counts first;
  rebuilding the imports, which recounts each play count from its history, counts the offsets
  in.
- **Moves** (ADR 0026) carry the offset with the row; when the new path's row has stats too,
  the offsets add, as the plays do, and the later set's clock goes with them.
- **Several tracks** each get the count typed, each its own offset and event. A track the
  index has no row for is left out.

## Alternatives considered

- **A `playCount` event with the count:** a later play from another Mac would either be lost
  under it or need the setter's view of every log to be undone.
- **A pseudo-player's import total:** totals only rise (ADR 0033), so a count couldn't be set
  lower.
- **Deltas, as the retired `counts` events:** two sets add up, which is what doubled the
  owner's Swinsian plays in phase 46.
- **Rewriting the history to N rows:** made-up dates in Listening Stats and the timeline.
- **Writing a play count tag to the files:** nothing reads one, and the tag writer only writes
  what the user edits in the tags (AGENTS.md).

## Consequences

Undo Tag Edit doesn't undo a set count, since it isn't a tag edit; setting it back does. An
earlier build reading a log with a `playCount` line reports it as an unknown event and skips
it.
