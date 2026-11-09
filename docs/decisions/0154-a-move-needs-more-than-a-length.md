# 0154. A scan's move needs more than a matching length

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0026](0026-sync-identity-is-the-relative-path.md) (matching)

## Context

ADR 0026 matched a gone path with stats to a track without stats when they were the only two
sharing codec, sample rate and length in frames, whatever their titles or folders, and whether
the track was new or had been in the library for years. On 8 Nov a scan whose listings missed
about 20,000 files (ADR 0151) left that many paths gone at once. 624 of them were alone in their
length with an unrelated track, mostly MP3s, whose lengths come in steps of 1,152 frames, and
the scan gave each one's plays and rating to that track: Rhythm & Sound's "Carrier" to Bvdub's
"Way Back When", 2,662 plays and 12 ratings in all. 606 of the 624 tracks had been in the
library before the scan. The moves went to the sync log too. A restore of the day's snapshot put
them back on this Mac, and the log was set aside (ADR 0038's restart).

The owner's rule: plays on the wrong song are worse than plays waiting to be placed.

## Decision

- **Audio facts make candidates, not matches.** Of the paths that share codec, rate and length,
  a gone path and a track match only when they're alone in being the same path but for the
  extension (a file converted in place), or, of those left, alone in sharing a title. A missing
  title on either side never matches.
- **Everything else waits in Lost Stats,** as ties already did, where Resolve Lost Stats… shows
  the candidates and the owner gives the stats by hand.
- **Moves read from another Mac's log,** and the move list's, are unchanged: they name both
  paths, so nothing is guessed.

## Alternatives considered

- **Only tracks the same scan added can take stats.** Rejected: a file moved into a folder
  that a later scan reads (0026's two-scan case) is new to that scan but not to the index, and
  the title already rules out the 624 seen here.
- **Compare a hash of the audio.** Rejected for now: it needs every file read whole once, over
  the NAS, to store the hashes. ADR 0026 names it as the thing to revisit.

## Consequences

- A file renamed and retitled at once, as a tagger renaming a whole library can do, no longer
  keeps its stats by itself: it shows in Lost Stats with its candidates.
- A different song with the same title, length and codec, alone in all three, can still take a
  gone path's stats. Two such files gone and arrived in one scan is far rarer than a length
  alone.
