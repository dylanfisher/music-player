# 0131. Matching library albums to Discogs releases

- **Date:** 2026-11-07
- **Status:** accepted
- **See also:** [0128](0128-discogs-survey.md) (the owner's tags), [0129](0129-custom-tag-fields.md)
  (the ids in the index), [0130](0130-discogs-catalog.md) (the catalog and its folding)

## Context

Phase 51's window sorts the library's albums into tiers by how well they fit a release in the
local catalog: Exact albums are applied in one batch after a review, Likely and Incomplete ones
are checked by hand. A wrong Exact writes another release's tags to a whole album, so the bar
the plan set is at least 95% of the owner's matched albums back as Exact or Likely with the same
release, ids hidden, and none Exact with another release. The owner decided the tie-break on
2026-11-07. Analyze over the whole library must not read 43k files over SMB, about 7 minutes
(ADR 0128).

## Decision

### The album side comes from the index

`LibraryIndex.discogsAlbums()` gives each album's title, artist (album artist, else artist),
label, catalog number, barcode, date and media, and its tracks' titles, lengths, disc and track
numbers and release ids, in disc and track order. `LABEL`, `CATALOGNUMBER`, `BARCODE` and
`DATE` are standard fields each format's reader maps (Vorbis comments, ID3 `TXXX`, MP4 freeform
items, YATE's spellings among them), already stored as `publisher`, `catalog_number`, `barcode`
and `date`, beside 51a's two Discogs ids. `MEDIA`, also a standard field, gains a `media`
column: YATE writes the release's format and descriptions there (`Vinyl (LP,Album)`), and the
tuning found it tells apart releases nothing else in the tags does. An album's values are its
first track's that has one. No file is read.

### Candidates

In the order found, each release once:

1. the release ids the tracks carry (a refresh of a matched album);
2. the releases with the album's barcode;
3. the releases with its label and catalog number: the whole `LABEL`, then each label of a
   " & " list, as YATE joins several;
4. the masters, expanded to all their releases, and the master-less releases whose artist
   and title fold as the album's do (`CatalogKey`). The title is also tried without a leading
   bracketed catalog number and without edition words after a dash; the artist also as the
   first name of a "feat.", "&", ",", "vs." or "x" list; Various Artists or no artist as
   Discogs's "Various".

### Scoring

- **The tracklist as files.** Headings are dropped, unless no row has a position, when the
  dump gave nothing to tell them from tracks. An index track is tried both as its sub-tracks
  and as one file; the better fit wins.
- **Titles** are folded as the catalog folds titles. Two count as the same when their edit
  distance over the longer length leaves at least `sameTitle`; one held whole in the other
  counts as `containedTitle`.
- **Same count:** file i is track i. **Different counts:** an in-order alignment pairs titles
  at least `pairedTitle` alike, so a bonus track or a hidden one leaves the rest mapped. The
  tracklist score is the paired similarity over the longer list.
- **Lengths** agree within `durationSeconds` or `durationFraction` of Discogs's, whichever is
  more, where Discogs has one. They only decide between Exact and Likely for the release
  chosen, not which releases tie: Discogs's lengths are typed by hand, and on the owner's
  matched albums 10% of the tagged releases' tracks are more than 3.8 s off the files (5% more
  than 6.4 s, 1% more than a minute).

### Tiers

- **Exact:** same count, every title the same in order, only one release so or one left after
  the tie-break, and every known length of that release agreeing.
- **Likely:** same count and a tracklist score of at least `likelyTracklist`; or every title in
  order but still tied, or with lengths that don't agree.
- **Incomplete:** another count, a weaker tracklist, or tracks with different release ids or
  only some with one.
- **No candidate**, and **Matched**: every track has one release id; that release is scored
  again for the refresh, and the others are listed.

The tie-break among the releases that fit the tracklist (same count, every title in order),
each step keeping the releases that pass when any do:

1. a barcode or catalog number spelled as the tags spell it;
2. a barcode or catalog number that folds as the tags' does;
3. a format the tags' `MEDIA` spells, as YATE writes it: the name, then the descriptions in
   brackets joined with ",";
4. a release date that is the tags' `DATE`;
5. File, CD, CDr or SACD over vinyl and the rest;
6. the master's main release.

Steps 1, 2, 5 and 6 are the owner's order (2026-11-07), step 1 split in two. Steps 3 and 4 are
what else YATE copies from the release into the tags, placed before the format step because on
the owner's albums they name the release he chose where the format step picks another: he
tagged the vinyl over an identical download 27 times among the first wrong Exacts. Among
releases that don't fit the tracklist, the best rank (tracklist, plus `durationWeight` times the
share of agreeing lengths, a release without lengths counting half) is chosen, with the same
tie-break.

The result per album is its tier, the chosen release, its tracks as files, each file's track,
and the other candidates best first.

### Thresholds and tuning

Every threshold is a constant in `MatchThreshold`. `TagCorpus --discogs-tuning` takes the
survey's cache of the watched folders (`.build/discogs-survey/files.jsonl`, read once, read
only), keeps the albums whose every track has one release id, hides the ids and matches them
against the real catalog, then again with the label, catalog number and barcode hidden too, as
an album YATE never tagged would be. Its report is `.build/discogs-tuning/report.txt`.

Tuned on 2026-11-07 with the 20261101 dump, 1,741 albums, on this Mac (`--discogs-tuning`,
release build, one thread):

| Run | Exact | Likely | Incomplete | No candidate | Same release, Exact or Likely | Exact, another release | Tagged release a candidate | Time |
|---|---|---|---|---|---|---|---|---|
| First, 3 s / 2%, the owner's steps only | 1,193 | 430 | 66 | 52 | 1,147 (65.9%) | 277 | 96.7% | 22.6 s, 13.0 ms an album |
| As built, tags | 1,420 | 238 | 66 | 17 | 1,516 (87.1%) | 81 | 98.8% | 23.4 s, 13.5 ms an album |
| As built, titles only | 1,073 | 484 | 68 | 116 | 1,005 (57.7%) | 251 | 92.4% | 3.1 s, 1.8 ms an album |

Where the files map to a track, the track is the one YATE's `DISCOGS_RELEASE_ORDINAL_POSITION`
(counted from 0) names for 12,576 of 13,609 files.

What moved the numbers: lengths out of the tie (277 to 223 wrong Exacts), the date and the
spelled number (to 146), `MEDIA` (to 81), and a fix to the catalog (51 albums with no candidate
to 17): the dumps write a release with no master as master 0, which the import kept, so no
master-less release had title keys.

**The bar isn't met: 87.1%, not 95%, and 81 Exact with another release, not none.** Why, from
the report's examples:

- **Incomplete by design, 66.** 55 of them chose the tagged release: the owner kept part of a
  release, or a release with tracks Discogs doesn't list. The plan's tiers make another count
  Incomplete, and the bar counts it as a miss, so 96.2% is the most it can reach.
- **Twins nothing in the tags tells apart, about 40 wrong Exacts.** The same tracklist, catalog
  number, date, `MEDIA` and country, settled by the owner's format and main release steps the
  other way from the owner's choice: Maurizio's M4.5 (tagged 712, chose 1075322, both German
  12" vinyl of one number), Bitches Brew (37006 against 12032942), A Night In Tunisia (7153691
  against 859105). Dropping those two steps leaves 41 wrong Exacts and 88.5%, so the steps cost
  40 albums.
- **Tags changed after YATE, or a release missing, the other 41.** A `DATE` that isn't the
  tagged release's, track titles that no longer fit it, three tagged releases not in the dump.

Zero wrong Exacts needs the owner to decide one of: that a win by format or main release alone
is Likely, not Exact; that the window's Exact counts these twins as right, since their tags
differ only in the release id and what the format step chose; or a lower bar.

### Running it

`matchAlbums(_:catalogAt:progress:)` runs on a detached task with a catalog connection of its
own, opened for the call, since the system SQLite fails a connection whose file an import
replaced (ADR 0130). It checks for cancellation before each album and reports albums done of
the total.

## Alternatives considered

- **Reading the files on Analyze.** Rejected: about 7 minutes over SMB for the whole library,
  for fields the index already holds.
- **New columns for YATE's `DISCOGS_CATALOG_NUMBER`.** Rejected: `CATALOGNUMBER` is on 1,737
  of the 1,741 matched albums and is the same number.
- **Lengths as a hard part of fitting the tracklist.** Rejected: the release the owner tagged
  often has lengths a few seconds off, and a twin without lengths then won Exact.
- **Agreeing lengths as a last tie-break step.** Tried and rejected: it chose the twin with
  lengths over the tagged one as often as the other way.
- **The release title as a tie-break step.** Not added: 8 wrong Exacts had the tagged
  release's title in the tags and the chosen one's differing, too few to add a step the owner
  didn't name.
- **Stopping at the first step that finds candidates.** Rejected: the window's Other Releases
  lists every candidate, and an Exact needs to know no other release fits as well.

## Consequences

51d shows the tiers and the mapping and makes public what its window calls. A catalog imported
before the master 0 fix has to be imported again. The steps after the owner's use tags YATE
writes; an album another tagger tagged falls through to the owner's steps, as the titles-only
run shows. Any change to a
threshold is tested by rerunning the tuning on the cache. Title lookups match the catalog's
canonical artist names only, as the catalog keeps no ANV keys; an album tagged with an ANV is
found by its barcode or catalog number.
