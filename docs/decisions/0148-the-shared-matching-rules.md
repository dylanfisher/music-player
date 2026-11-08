# 0148. The matching rules music-recommender shares, kept in step by a golden file

- **Date:** 2026-11-08
- **Status:** Accepted
- **See also:** [0130](0130-discogs-catalog.md) (the catalog's keys),
  [0131](0131-discogs-matching.md) (the matcher), [0146](0146-staged-tag-writes.md) (what a
  clean match writes); music-recommender's ADR 0010 (its copy of these rules)

## Context

Phase 54's service, music-recommender, ranks Soulseek folders against a release before it
downloads one, and reports which file is which track by the release's positions. The player
then matches the staged files against the same release, and a run is clean only when its
mapping agrees with the service's (ADR 0146). So the two must fold, compare and score titles
the same way, or an album the service accepted turns into a discrepancy after a download.

The service is Rust with no crate for Unicode folding. Its ADR 0010 copies the player's rules
(`CatalogKey.fold`, `TitleSimilarity`, `ReleaseScore`, `MatchThreshold`) with one change: in
place of Foundation's `diacriticInsensitive` and `caseInsensitive` folding, a hand-written
table maps the 190 letters of U+00C0 to U+017F (less `×` and `÷`) to their ASCII base, ASCII
is lowercased, and any other character is lowercased with `char::to_lowercase`, keeping its
marks. Its golden file,
`rank-golden.json`, holds the thresholds, the table, the edition words and cases of folding,
title similarity, tracklist scores and ranking.

Foundation and the table disagree. Run against the golden cases, the player's fold missed 7
of 56 and its similarity 2 of 16: Foundation keeps `æ`, `ø`, `ł`, `đ`, `þ`, `ð` and `ĳ` as they
are, where the table makes them `ae`, `o`, `l`, `d`, `th`, `d` and `ij`, so "Ænima" and "Aenima"
were 0.67 alike, not 1. Foundation also drops marks outside the table, such as Vietnamese,
which the service keeps.

## Decision

- **The matcher folds with the table, then Foundation.** `CatalogKey.matchKey` takes
  `fold`'s steps in its order (trim, a trailing `(digits)`, bracketed edition words for a
  title, `&` as "and", a leading "the ", only letters and digits kept), maps characters
  through `LatinFold.table`, and then applies Foundation's case and accent folding to
  everything else. `TitleSimilarity`, and so `ReleaseScore`, the tiers and the tagger's
  side-by-side rows, compare titles by it. The library tagger is at least as lenient as it was
  before the table, for all scripts: "Кино" and "кино" are equal.
- **The one difference from the service: marks outside the table.** Foundation drops
  diacritics the table doesn't cover, such as Vietnamese, where the service keeps them. So
  "Việt" and "Viet" match in the player and not in the service. The service is the stricter
  side and the player re-checks at auto-tag, so the difference shows as a discrepancy, never
  as a wrong write. The golden cases hold no such marks, so no case needs an exception, and
  `CatalogKeyTests` covers the player's side.
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
`c9f9134c5460472361fbd2005fbee149d3630832caf1f4706c57ce5eaaddf2d2`

### Deliberate differences

- **The fold's `words`.** Each fold case also gives the folded words joined with spaces, which
  the service searches Soulseek with. The player never builds a query, so only `key`, the
  words run together, is checked.
- **The ranking cases.** They rank peers' folders by format, size and slots, which only the
  service does; the player checks a staged album's mapping instead (ADR 0146).
- **A file with no length.** The service leaves a file it has no length for out of the
  duration counts; the player always reads one from the file. The golden score cases pair such
  a file only with a track of no length, or with none, so the test gives it 0 and checks that
  this holds.

## Alternatives considered

- **Keeping Foundation and listing the 9 cases as differences.** Rejected: each would show as
  a discrepancy on a real download with an `ø` or `æ` in a title, which the shared file exists
  to prevent.
- **Folding only with the table, as the service first did.** Rejected: it kept Cyrillic case
  and every mark outside the table, so the library tagger got stricter ("Кино" against "кино"
  scored 0.75). The service now lowercases such characters too (its ADR 0010).
- **Moving the catalog's keys to the table too.** Rejected for now, for the reimport above. It
  can come with the next change that rebuilds the catalog anyway.

## Consequences

Within the table, letters Foundation kept now fold, so "Røyksopp" and "Royksopp" are the same
title. Outside it nothing gets stricter. Rust's and Swift's Unicode case tables can differ by
version for rare characters, which the golden cases avoid. A change to the table, the edition words, a threshold or the
score is a change to the golden file, its SHA-256 here and in music-recommender's ADR 0010, and
both repos' tests, in step.
