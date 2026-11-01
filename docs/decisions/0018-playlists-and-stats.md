# 0018. Playlists live with the stats, keyed by path; a play counts after half or 4 minutes

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0008](0008-library-schema-identity-and-stats-by-path.md),
  [0016](0016-palette.md)
- **Amended by:** [0022](0022-stable-track-identity-and-play-timeline.md) (entries, stats and
  History key on a path ID; the play timeline)

## Context

Phase 7 adds manual and smart playlists, play and skip counts, last played, ratings and a
history view. The index can be dropped and rebuilt from a rescan at any time (0008), so
anything the user made has to survive that, and it must never be written to the music files.
The library is 43k tracks, and a smart playlist is listed again on every library change.

## Decision

- **Playlists are stats.** `playlists` and `playlist_entries` are created by the stats SQL,
  which an index rebuild keeps. Entries name tracks by path, like plays and ratings, so a
  rebuild or rescan finds them again. A playlist's own ID is safe to keep and to key on (the
  saved sidebar source `playlist:<id>`, which the palette's key reuses), since only a change to
  the stats SQL drops it, and then the playlist is gone too. IDs are `AUTOINCREMENT`, so a
  deleted playlist's ID never comes back to name another. Keying by ID survives a rename, where
  a name wouldn't. Entries whose file left the index aren't listed; the status line counts
  them.
- **Each track at most once per manual playlist.** The table selects by track ID, so a track
  listed twice would select and move as one. Adding a track already there does nothing.
- **Smart rules are JSON in `playlists.rules`**, decoded strictly at every level (unknown keys,
  a comparison the field can't take, a value of the wrong kind, a limit of 0 all fail). Rules
  this build can't read leave the playlist listed with a warning sign; showing it fails with the
  reason, and saving new rules replaces them. Rules compile to one `IN (SELECT …)` with the
  plays and ratings joined by path; text compares the folded sort columns with a folded value,
  so case and accents don't matter where the index folds. A limit's order breaks ties by path,
  so a rebuild picks the same tracks. No "random" order, which would reshuffle on every live
  refresh.
- **Sort follows the source.** A manual playlist opens sorted by Order (its own order) and
  History by Last Played, newest first; folders and smart playlists keep the table's sort.
  Leaving a manual playlist or History puts back the sort it replaced, unless the user chose
  another there; Order never outlives its playlist. Rows move by dragging only while a manual
  playlist is sorted by Order, ascending, and rows dropped on their own block stay put. Back and
  Forward record a source only once it has shown.
- **Numbers compare whole**, as the table shows them: a 200.4 s track "is 200". A date that
  doesn't start with four digits has no year, so it matches no year rule.
- **History** lists each track played, once, from the `history` log.
- **A play counts** once the track has played, not paused, for half its length or 240 s,
  whichever is first; a track of unknown length needs 240 s. Wall-clock listening time counts,
  so seeking ahead doesn't. **A skip** is another track starting before the play counted;
  stopping isn't a skip (it ends the listen), and neither is a track that reached its end.
  `PlayCounter` (Playback) reads the engine's existing updates and says when the current track
  would count; `PlayTracker` sleeps until then, once per track instead of polling, and sleeps
  again if it wakes early. Nothing near the IO proc changes.
- **Ratings** are 0 to 5 whole stars; 0 deletes the row.
- **⌘⌫** removes from the queue when the queue has the keys and from a manual playlist when the
  track table has them; anywhere else it's off.
- **Drags carry track IDs** in a pasteboard type only this app reads, never file URLs, so no
  drag can let Finder copy or move a music file.
- **The benchmark budget** for listing a six-rule smart playlist with a limit over 43k tracks
  is 50 ms on Apple Silicon, so a live refresh stays inside a frame or three. The old Mac's
  150 ms is a guess until its checkpoint.

## Alternatives considered

- **Entries by `files.id`** — rejected for 0008's reason: a rebuild reassigns IDs.
- **Playlists in `state.json`** — rejected: smart rules join the stats in SQL, and the state
  file is discarded whole on a mismatch, which would lose every playlist.
- **`NSPredicateEditor`** for the rules — rejected: "in the last N days" and units need custom
  row templates, and turning `NSPredicate` back into stored rules is more code than the plain
  rows of pop-up buttons, which are native controls too.
- **Counting a play at the track's end** — rejected: a track stopped at 90% would never count,
  and Music and Swinsian count earlier.
- **Duplicates in manual playlists** — rejected for now, as above; it would need entries keyed
  by position all through the table.

## Consequences

Changing the stats SQL now drops playlists as well as plays (pre-release only). A file moved or
renamed leaves its playlist entries and stats on the old path, as 0008 says. Composer, comment,
codec and path aren't folded, so their text rules ignore case for ASCII only.
