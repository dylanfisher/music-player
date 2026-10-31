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
  frecency does too. An album's row names its artist. Go to Item's rows are `track:<row>:<id>` and choosing one does nothing if the
  row no longer shows that track.
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
  has been prepared.
- **Bench measures Go to Item**, the larger list, per keystroke over every fixture track, against
  the 30 ms budget. ⌘K lists a few thousand items and costs less.
- **Playlists** join ⌘K in phase 7, when they exist. **Settings** that aren't commands join with
  the Settings window, which choosing one opens at its row.
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
