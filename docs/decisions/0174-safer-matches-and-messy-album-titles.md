# 0174. Titles Fit, a safer Safe, and finding albums with messy titles

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0131](0131-discogs-matching.md) (the tiers, the tie-break, the tuning),
  [0148](0148-the-shared-matching-rules.md) (the rules the golden file pins),
  [0170](0170-match-confidence-and-the-safe-tab.md) (the confidence and the Safe tab)

## Context

The owner wants to apply more of a whole-library run without reviewing each album. Safe works
well, and they asked for a second tab: every title the same and in order, with some lengths
different. A title match proves little when the titles are "Untitled 1", "Untitled 2" and so on,
so that tab has to tell those apart.

They also asked for albums whose title carries label information, such as
`Third Eye Foundation – Ghost [WIGCD 32]`, which no search found. A survey of the library's
6,566 album titles found these conventions: a trailing catalog number in square brackets or
parentheses (about 420), a leading one before the title with a format word after it, as in
`(CURLE 024) Talis / Into The Red WEB` (about 330), `Vinyl`, `WEB`, `320`, `EP`, `LP` and `CD2`
at the end, `[EP]` and `(Vinyl)`, years in square brackets, and the artist's name before a dash.
No title uses braces. Before this change, 2,789 of the 4,905 albums no track gives a release id
found no candidate.

## Decision

- **More spellings of the title.** After the two variants the prototype had,
  `CatalogKey.titleVariants` cleans the title one step at a time, and each step is a spelling to
  look up. A step removes one of: a trailing format or disc word, a trailing bracket that holds
  a digit or only format words, a leading bracket that holds a digit, or the artist's name (or
  "VA") before a dash. Each spelling is looked up in addition to the title, so a step that cuts a
  real title short only adds candidates, and the tracklist still has to fit. The API tries a
  spelling only after the ones before it found nothing.
- **The title's catalog number.** When the tags have no catalog number, the one the title names in
  a bracket at its start or end (letters and digits, not a year or a disc) is used: with the
  label for the lookup, and in the tie-break. Without a label it isn't looked up, because the
  catalog indexes numbers by label first, so a number alone would read the whole table.
- **The artist alone.** When no search finds any candidate, the matcher scores the artist's
  releases: the main release of each of the first 50 masters credited to the artist, and the
  other releases of a master only when its main release's titles pair with the album's (a
  tracklist score of at least 0.3). It keeps a release only when it is Likely. A release found
  this way says "found by artist only", costs 15 points of confidence, and is at most Likely,
  never Exact or Safe. On the tuning set these matches were about 75% right, too weak to apply
  without review. Compilations and Discogs's "Unknown Artist" credit are not searched. It doesn't
  run for an album the title search found something for: on Incomplete albums it found 1 right,
  5 other pressings and 4 wrong albums, and it took a third of the time.
- **Distinctive titles** (`TitleDistinctness`): a title counts as distinctive when, after its
  numbers, side positions ("A2", "CD1"), Roman numerals and placeholder words ("untitled",
  "track", "part", "intro" and the like) are removed, it keeps at least 3 letters and no other
  title on the album is left the same.
- **A tie with another album.** The tied releases are other albums when they belong to more than
  one master and also have more than one title. Neither alone is enough: Discogs files some
  albums under two masters of one title, and titles releases of one master differently.
- **Safe** keeps the rule from ADR 0170, and now also needs the tie, if there is one, to be with
  the same album, and needs either half the titles distinctive or every file's length known.
- **Titles Fit**, a tab after Safe, lists Likely albums where every title fits in order, the
  count fits and some lengths differ, and the album has at least 3 files, at least 75% of its
  titles distinctive, at least half of its known lengths agreeing, and no tie with another album.
  Apply to All works there as it does in the other tabs. Like Safe, it's a view of Likely.
  Both tabs are decided in the matcher as `AlbumMatch.safety`, so the tuning tool counts the same
  albums the window lists.
- **The confidence** loses 15 times the share of titles that aren't distinctive, times the share
  of files whose length doesn't agree, so lengths that agree make up for titles that say little.
  It loses 5 more for a tie with another album. The matcher's tiers, its ranking and the golden
  file's rules don't change.
- **Each tab has a tooltip** saying what it lists.

## Measured

The tuning tool now reports each Apply to All tab as right (the tagged release or a twin), another
pressing of the same master, or wrong, and runs on the untagged albums too. Against the
2026-11-07 survey:

| Run | Before | After |
|---|---|---|
| Tags: Exact or Likely, right | 1564 of 1632 | 1573 |
| Tags: Exact, wrong release | 29 | 29 |
| Tags: Safe, wrong album | 48, 0 | 43, 0 |
| Tags: Titles Fit, wrong album | — | 98, 0 |
| Titles only: Exact or Likely, right | 1004 | 1038 |
| Titles only: Safe, wrong album | 376, 2 | 364, 2 |
| Titles only: Titles Fit, wrong album | — | 83, 0 |
| Untagged: no candidate | 2789 of 4905 | 1761 |
| Untagged: Safe and Titles Fit | 185 | 220 and 64 |

The two wrong Safe albums with titles only are the same tracklist under another release: an
unlinked release of the same title, and a two-albums-on-one CD. The untagged run went from 1.2 ms
an album to 3.3 ms, nearly all of it the artist-only reads in the 37 GB catalog.

## Alternatives rejected

- **Stripping every trailing bracket.** "(The Remixes)" and "(Black Box)" are part of real
  titles. Brackets without a digit are kept unless they hold only format words.
- **Adding the format words to the edition words.** That list is in the golden file shared with
  music-recommender (ADR 0148). Spellings to look up are the player's own.
- **Looking up a title's catalog number without a label.** It needs a new index, which means
  importing the catalog again.
- **A tie only within one master.** It took 26 albums out of Safe with titles only, all of them
  right or another pressing, to remove one that had the same tracklist anyway.
- **Artist-only matches in Exact.** About 1 in 4 was another album.

## Consequences

The music-recommender service still looks albums up the old way, so on its side these albums stay
unmatched until it has the same spellings. A whole-library run takes longer, about 2 seconds more
for every 1,000 untagged albums on this Mac.
