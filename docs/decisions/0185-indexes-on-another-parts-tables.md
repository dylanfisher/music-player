# 0185. Indexes on another part's tables

- **Date:** 2026-11-10
- **Status:** accepted

## Context

Phase 73's performance audit found that opening Listening Stats spent 211 of its 290 ms on
the first-plays query: `min(played_at)` for each path, a sort of all 1M rows of `history`.
An index on `history (path_id, played_at)` cuts it to 26 ms. `history` belongs to the stats
part, whose SQL is its identity: any change to that text rebuilds the part, which would
discard the owner's plays, ratings and playlists.

## Decision

**An index on another part's tables goes in a part of its own.** `SchemaPart.historyByPath`
holds only `CREATE INDEX history_path_played ON history (path_id, played_at)`, after
`stats`, and creates no tables. `SchemaPart.indexes` names the indexes a part makes, and a
rebuild drops them before it runs the part's SQL, since dropping the part's tables can't
remove an index on someone else's. Opening an index without the part creates the index and
discards nothing. `firstPlays` reads `history INDEXED BY history_path_played`.

Opening Stats on Past Month went from 299 to 84 ms. The history table and its indexes went
from 28.7 to about 47 MB at 1M plays, so that row's budget went from 40 to 50 MB.

## Alternatives considered

- **Widening `history_path` to `(path_id, played_at)`.** It saves the most space, but it
  changes the stats part's SQL and so rebuilds it.
- **Also an index on `played_at`, for the bounded periods.** It would go over even the new
  size budget, and All Time, the slowest period at about 230 ms, scans every row anyway.
- **Dropping `history_path` from the new part,** since the new index serves its lookups as a
  prefix: about 12 MB less, but the stats part's SQL would then name an index that isn't
  there, and a rebuild of the new part would have to recreate it.

## Consequences

- Each play recorded adds a row to two indexes on `history`, not one (0.07 to 0.16 ms a
  play, inside the 1 ms budget).
- The next index on another part's tables follows the same pattern.
