# 0016. The palette's sources, frecency and matching units

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md)

## Context

[0012](0012-searcher-conventions.md) ports Searcher's ⌘K and ⌘P palette (its 0079, 0085, 0087
and 0101). Searcher's sources are folders, workspaces and commands; this app's are commands,
settings and the library. A few choices follow from that.

## Decision

- **Items are keyed by what they name**, not by row ID: `command:<id>`, `artist:<name>`,
  `genre:<name>`, and `album:<title>␟<artist>` (a unit separator between), since the index
  holds one album per title and artist. IDs change when the index is rebuilt; names survive, so
  frecency does too. An album's row names its artist. Go to Item's rows are `track:<id>`, and choosing one shows that
  track, as Show Current Track does (amended below).
- **Frecency counts palette choices and plays.** A track starting counts once for its artist, its
  album and its genre. Go to Item's rows are ranked by the match alone, as Searcher's are, so
  they aren't counted. The log (at most 1,000 keys, sorted, the least frecent dropped) and the
  panel's place are app state in `state.json`.
- **Matching works on folded Unicode scalars**, not UTF-8 bytes: each character is folded
  (lowercase, no accents) and each scalar of the result is one unit, keeping the scores and rules
  of 0079 exactly. A brute-force test checks the dynamic program against every placement on
  5,000 random texts.
- **Preparing Go to Item's rows runs off the main actor** as the palette opens: about 120 ms for
  43k titles on Apple Silicon. The empty query lists the first rows at once; typing ranks what
  has been prepared. (Amended 2026-11-02.) That happens on the first ⌘P only: its rows are kept
  and the next open lists them at once. The browser's refresh after a library change (a scan
  that read or removed files, an import, a tag edit, a removal, a sync) drops them, and the next
  ⌘P builds them again. Rebuilding then rather than on the change keeps a long scan, which
  refreshes every 2 s, from preparing 43k titles each time. A build the library changed under
  is shown but not kept.
  (Amended 2026-11-02.) Both palettes rank their opening rows on the main actor before the panel
  shows, so its first frame has them. An empty query matches nothing, so this costs about 2 ms
  for ⌘P's 43k kept rows on Apple Silicon; Bench holds it to one frame on the old Mac. Typing
  still ranks off the main actor.
- **Bench measures Go to Item**, the larger list, per keystroke over every fixture track, against
  the 30 ms budget. ⌘K lists a few thousand items and costs less.
- **Playlists** join ⌘K in phase 7, when they exist. **Settings** that aren't commands join with
  the Settings window, which choosing one opens at its row.
- **Two palettes by what they find (amended 2026-11-01).** The owner asked for ⌘K to hold what
  the app does and ⌘P what it plays. ⌘K lists commands, settings, outputs ([0045](0045-output-picker.md)), playlists and genres; ⌘P lists
  artists, albums and every track in the library, every matching artist first, then albums, then
  tracks, each kind ranked by the score and frecency rules above. Each kind keeps its own best
  50, so a query matching many artists still shows its albums and tracks, and a keystroke over
  43k tracks still costs one score per row. The tracks are the whole library's, not the
  current list's as Searcher's are: with a playlist shown the owner still expects ⌘P to find any
  track. Choosing one selects it where it shows, or shows the whole library first when the
  list, a pane or the search hides it; the timeline's rows are plays, so it leaves the timeline.
  Both palettes share one frecency log, since their
  keys can't collide. The alternate chords ⇧⌘P and ⇧⌘K are gone, so each palette has one chord.
- **⌘K's empty query lists only commands (amended 2026-11-02).** A frecent genre listed above
  the commands before anything was typed, and the list changed as genres arrived. Settings,
  outputs, playlists and genres show once the user types, ranked as before.
- `--snapshot-of palette` opens ⌘K before the snapshot, so the panel can be checked on a Mac
  where screen recording isn't allowed.

## Alternatives considered

- **Keying entries by row ID** — rejected: a rescan that rebuilds the index would reset frecency.
- **Counting plays per track** — rejected: tracks aren't in ⌘K, so their frecency would rank
  nothing.
- **Byte-level matching, as Searcher's** — rejected: Swift strings fold per character, and units of
  whole scalars keep a non-ASCII letter matching as one letter without Searcher's continuation-
  byte rule.

## Consequences

Two artists with one name share a palette row and its frecency, as they share a row of the
artists table. Two albums with one title and different artists are two rows.
