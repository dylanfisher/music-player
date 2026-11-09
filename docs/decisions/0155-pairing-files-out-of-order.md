# 0155. Files out of order are paired by title, for the window only

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0131](0131-discogs-matching.md) (same count: file i is track i)
- **See also:** [0148](0148-the-shared-matching-rules.md) (the rules music-recommender shares)

## Context

With the same count, ADR 0131 maps file i to track i. A white-label 12" whose files were
numbered A and B the wrong way round, "Rise Up (Instrumental)" then "Rise Up (Copeland PMT
Club Mix)", showed each file beside the other's track, both marked different, though both
titles were exact. Fixing it took a drag per row.

`ReleaseScore.score`, its mapping and tracklist score included, is one of the rules
music-recommender copies, checked case by case against `rank-golden.json` (ADR 0148).

## Decision

- **The chosen release is paired again by title.** With the same count and not every title in
  order, each file goes to the track whose title fits it best, one file to a track, by the
  Hungarian algorithm over the similarities `TitleSimilarity` gives, counting those under
  `pairedTitle` as 0. A tie keeps a file in its place, so repeated titles such as "Untitled"
  don't move. The new pairing is kept only when it pairs more similarity than the files in
  place.
- **The score the tier and the ranking read is unchanged.** `tracklist` and `titlesInOrder`
  stay the in-order ones, so the golden cases and the service agree as before, and an album
  out of order stays Likely or Incomplete for the owner to review. Only the mapping the window
  proposes, and the reasons and length counts read from it, follow the new pairing.
- **A reason says so:** "2 files are out of the release's order".

## Alternatives considered

- **Scoring the best pairing, so a reordered album could be Exact.** Rejected: it changes the
  shared rules and the golden file, and files out of order usually mean their track numbers
  are wrong, which the owner should see before Apply to All writes positions.
- **Greedy pairing, highest similarity first.** Rejected: it can take a close second-best pair
  and leave a file with nothing, where the Hungarian algorithm finds the best total.

## Consequences

- Albums of different counts still use the in-order alignment: a file out of order there stays
  unpaired, for a drag.
- Staged downloads are unaffected: they need Exact, and an Exact album is in order already.
