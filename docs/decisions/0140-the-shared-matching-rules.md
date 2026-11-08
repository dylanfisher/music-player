# 0140. The matching rules music-recommender shares, kept in step by a golden file

- **Date:** 2026-11-08
- **Status:** Accepted
- **See also:** [0130](0130-discogs-catalog.md) (the catalog's keys),
  [0131](0131-discogs-matching.md) (the matcher), [0138](0138-staged-tag-writes.md) (what a
  clean match writes); music-recommender's ADR 0010 (its copy of these rules)

## Context

Phase 54's service, music-recommender, ranks Soulseek folders against a release before it
downloads one, and reports which file is which track by the release's positions. The player
then matches the staged files against the same release, and a run is clean only when its
mapping agrees with the service's (ADR 0138). So the two must fold, compare and score titles
the same way, or an album the service accepted turns into a discrepancy after a download.

The service is Rust with no crate for Unicode folding. Its ADR 0010 copies the player's rules
(`CatalogKey.fold`, `TitleSimilarity`, `ReleaseScore`, `MatchThreshold`) with one change: in
place of Foundation's `diacriticInsensitive` and `caseInsensitive` folding, a hand-written
table maps the 190 letters of U+00C0 to U+017F (less `×` and `÷`) to their ASCII base, ASCII
is lowercased, and any other character is kept as it is, case included. Its golden file,
`rank-golden.json`, holds the thresholds, the table, the edition words and cases of folding,
title similarity, tracklist scores and ranking.

Foundation and the table disagree. Run against the golden cases, the player's fold missed 7
of 56 and its similarity 2 of 16: Foundation keeps `æ`, `ø`, `ł`, `đ`, `þ`, `ð` and `ĳ` as they
are, where the table makes them `ae`, `o`, `l`, `d`, `th`, `d` and `ij`, so "Ænima" and "Aenima"
were 0.67 alike, not 1; and Foundation lowercases Cyrillic and drops Vietnamese marks, which
the table keeps, so "Кино" and "кино" were 1, not 0.75.

## Decision

- **The matcher folds with the table.** `CatalogKey.matchKey` takes `fold`'s steps in its
  order (trim, a trailing `(digits)`, bracketed edition words for a title, `&` as "and", a
  leading "the ", only letters and digits kept) and maps characters through `LatinFold.table`
  in place of Foundation. `TitleSimilarity`, and so `ReleaseScore`, the tiers and the tagger's
  side-by-side rows, compare titles by it. The player agrees with the service on every fold,
  similarity and score case.
- **The catalog's keys stay on Foundation.** `CatalogKey.fold` still makes the keys the
  catalog stores at import and looks releases up by (ADR 0130). Moving them to the table would
  leave every stored key for a name with `ø` or `ł` unfindable until the dumps were imported
  again, which takes hours on the DAC Mac. The service never looks up the catalog, so lookups
  aren't part of the shared rules.
- **The golden file is committed byte for byte** at
  `Tests/DiscogsTests/Fixtures/rank-golden.json`. `MatchingRulesGoldenTests` checks its
  SHA-256, the thresholds, the table and the edition words against the player's own constants,
  and runs its fold, similarity and score cases against `matchKey`, `TitleSimilarity` and
  `ReleaseScore.score`.

**SHA-256 of `rank-golden.json`:**
`01af1a94f196bc82a7a62aa8457770cfce5d8be09a58677e77c8ac120728d97e`

### Deliberate differences

- **The fold's `words`.** Each fold case also gives the folded words joined with spaces, which
  the service searches Soulseek with. The player never builds a query, so only `key`, the
  words run together, is checked.
- **The ranking cases.** They rank peers' folders by format, size and slots, which only the
  service does; the player checks a staged album's mapping instead (ADR 0138).
- **A file with no length.** The service leaves a file it has no length for out of the
  duration counts; the player always reads one from the file. The golden score cases pair such
  a file only with a track of no length, or with none, so the test gives it 0 and checks that
  this holds.

## Alternatives considered

- **Keeping Foundation and listing the 9 cases as differences.** Rejected: each would show as
  a discrepancy on a real download with an `ø` or `æ` in a title, which the shared file exists
  to prevent.
- **Applying the table, then Foundation to what's left.** Rejected: the player would still
  disagree on Cyrillic case and Vietnamese marks, and the golden file would no longer say what
  either side does.
- **Moving the catalog's keys to the table too.** Rejected for now, for the reimport above. It
  can come with the next change that rebuilds the catalog anyway.

## Consequences

Titles outside Latin-1 and Latin Extended-A now compare by case and marks in the tagger: a
Cyrillic title tagged in capitals against Discogs's mixed case scores lower than it did, and
may drop from Exact to Likely. Within the table, letters Foundation kept now fold, so "Røyksopp"
and "Royksopp" are the same title. A change to the table, the edition words, a threshold or the
score is a change to the golden file, its SHA-256 here and in music-recommender's ADR 0010, and
both repos' tests, in step.
