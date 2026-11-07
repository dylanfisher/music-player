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

The tie-break among the releases that fit the tracklist (same count, every title in order).
Each step gives each release a weight and keeps those of the highest weight, when any is above
0:

1. a barcode or catalog number spelled as the tags spell it;
2. a barcode or catalog number that folds as the tags' does;
3. a format the tags' `MEDIA` names: first as YATE writes it (the name, then the descriptions
   in brackets joined with ","), then a format of that name holding the tags' descriptions
   among its own;
4. a release date that is the tags' `DATE`: first as written, then as far as both say
   (`1965` and `1965-01-00`);
5. File, CD, CDr or SACD over vinyl and the rest;
6. the master's main release.

In steps 1 and 2 a catalog number on the first label weighs 2 and on another label 1, since
`CATALOGNUMBER` is the first label's (ADR 0128), and a matching barcode adds 1, so a release
with both beats one with either. Steps 3 and 4 match a release as Discogs has it now and then
as it has since been filled in: the dump is newer than the tags, and releases gain
descriptions and fuller dates. The owner approved this order on 2026-11-07: his own (barcode
or catalog number, format, main release) with step 1 split in two and `MEDIA` and `DATE`,
which YATE copies from the release, before the format. Among releases that don't fit the
tracklist, the best rank (tracklist, plus `durationWeight` times the share of agreeing
lengths, a release without lengths counting half) is chosen, with the same tie-break.

The result per album is its tier, the chosen release, its tracks as files, each file's track,
and the other candidates best first.

### Thresholds and tuning

Every threshold is a constant in `MatchThreshold`. `TagCorpus --discogs-tuning` takes the
survey's cache of the watched folders (`.build/discogs-survey/files.jsonl`, read once, read
only), keeps the albums whose every track has one release id, hides the ids and matches them
against the real catalog, then again with the label, catalog number, barcode, date and media
hidden too, as an album YATE never tagged would be. Its report is `.build/discogs-tuning/report.txt`.

**The bar,** as the owner decided it on 2026-11-07: at least 95% of the counted albums come
back Exact or Likely with the tagged release or a twin of it, and none Exact with a release
that is neither. A twin is equal to the tagged release in every tag the matcher compares, as
YATE writes them: the tracklist as files hold it, the first label's catalog number, the first
barcode, the release date, `MEDIA` and the country (`CatalogRelease.isTwin`). An album left
Incomplete with the tagged release or a twin chosen, because its files are another count than
the release's, isn't counted: the owner kept part of a release, or tracks Discogs doesn't list.
Twins stay Exact. The report gives the bar, then the raw numbers as first measured.

Tuned on 2026-11-07 with the 20261101 dump, 1,741 albums, on this Mac (`--discogs-tuning`,
release build, one thread):

| Run | Left out | Twins | Same or twin, of those counted | Exact, neither |
|---|---|---|---|---|
| As built, tags | 52 | 16 | 1,565 of 1,689 (92.7%) | 50 |
| As built, titles only | 38 | 7 | 1,012 of 1,703 (59.4%) | 245 |

| Run, raw | Exact | Likely | Incomplete | No candidate | Same release, Exact or Likely | Exact, another release | Tagged release a candidate | Time |
|---|---|---|---|---|---|---|---|---|
| First, 3 s / 2%, the owner's steps only | 1,193 | 430 | 66 | 52 | 1,147 (65.9%) | 277 | 96.7% | 22.6 s, 13.0 ms an album |
| As built, tags | 1,440 | 218 | 66 | 17 | 1,549 (89.0%) | 61 | 98.8% | 24.8 s, 14.3 ms an album |
| As built, titles only | 1,073 | 484 | 68 | 116 | 1,005 (57.7%) | 251 | 92.4% | 2.0 s, 1.2 ms an album |

Where the files map to a track, the track is the one YATE's `DISCOGS_RELEASE_ORDINAL_POSITION`
(counted from 0) names for 12,979 of 14,034 files.

What moved the raw wrong Exacts: lengths out of the tie (277 to 223), the date and the spelled
number (to 146), `MEDIA` (to 81), and a fix to the catalog (51 albums with no candidate to 17):
the dumps write a release with no master as master 0, which the import kept, so no
master-less release had title keys. Then the first label's number, a barcode and a number
together, and `MEDIA` and `DATE` as Discogs has since filled them in (to 61).

**The bar isn't met: 92.7%, not 95%, and 50 Exact with neither the tagged release nor a twin,
not none.** The 50, from the report:

- **The tagged release doesn't fit the files, 17.** Another count than the files while another
  release fits (9: Check Your Head, tagged 1710722; Cuspide Des Sirènes, tagged 28366390), titles the owner or Discogs
  has changed since (5: Barbados Wild Horses, tagged 28206643; DJ-Kicks, tagged 9338298), and
  the tagged release no longer in the dump (3: GAIA 11, tagged 28362274).
- **The tags no longer say what the tagged release says, about 20.** Discogs has changed the
  release's `MEDIA` or date since YATE tagged the files, beyond what step 3 and 4 fit, while
  another release has what the tags say: Bitches Brew (the tags' `1970-06-00` is chosen 12032942's
  date; tagged 37006 is now `1970-03-30`), A Night In Tunisia (tagged 7153691 has lost its date),
  Ancient Tones (tagged 2110456), Atomic Bomb (tagged 1378781).
- **Only the country tells them apart, about 13.** A Love Supreme (tagged US 857505, chose
  Canada 2552888), Born Like This (tagged 1701916), Buena Vista Social Club (tagged 3321641).
  The country isn't in the index or a tie-break step; adding it would change the approved
  order.
- The rest, a handful, differ only in the catalog number Discogs now gives the first label.

The misses that aren't Exact are 74: Likely with another release where the tie stayed, the
Incompletes with another release chosen, and the 17 albums with no candidate.

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
- **A number on any label weighing the same.** Rejected: `CATALOGNUMBER` is the first label's,
  and a release that has it on a second label (a distributor's) is another pressing.
- **Stopping at the first step that finds candidates.** Rejected: the window's Other Releases
  lists every candidate, and an Exact needs to know no other release fits as well.

## Consequences

51d shows the tiers and the mapping and makes public what its window calls. A catalog imported
before the master 0 fix has to be imported again. The steps after the owner's use tags YATE
writes; an album another tagger tagged falls through to the owner's steps, as the titles-only
run shows. Any change to a
threshold is tested by rerunning the tuning on the cache. Title lookups match the catalog's
canonical artist names only, as the catalog keeps no ANV keys; an album tagged with an ANV is
found by its barcode or catalog number. Title keys for name variations are planned for 51e.
