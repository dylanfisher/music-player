# 0131. Matching library albums to Discogs releases

- **Date:** 2026-11-07
- **Status:** accepted
- **See also:** [0128](0128-discogs-survey.md) (the owner's tags), [0129](0129-custom-tag-fields.md)
  (the ids in the index), [0130](0130-discogs-catalog.md) (the catalog and its folding)
- **Amended by:** [0155](0155-pairing-files-out-of-order.md): the window pairs files out of
  order by title

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
label, catalog number, barcode, date, media and country, and its tracks' titles, lengths, disc and track
numbers and release ids, in disc and track order. `LABEL`, `CATALOGNUMBER`, `BARCODE` and
`DATE` are standard fields each format's reader maps (Vorbis comments, ID3 `TXXX`, MP4 freeform
items, YATE's spellings among them), already stored as `publisher`, `catalog_number`, `barcode`
and `date`, beside 51a's two Discogs ids. `MEDIA`, also a standard field, gains a `media`
column: YATE writes the release's format and descriptions there (`Vinyl (LP,Album)`), and the
tuning found it tells apart releases nothing else in the tags does. The release's country, a
custom key, gains a `country` column, from the first of YATE's keys a file has
(`DiscogsKey.releaseCountry`): `DISCOGS_ALBUM_RELEASECOUNTRY` in FLAC, `Discogs Album Release
Country` in MP4 and ID3, then the `COUNTRY` YATE writes beside them in every format. An album's
values are its first track's that has one. No file is read.

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
  again for the refresh, and the others are listed. Apply to All writes Matched albums as it
  does Exact and Likely ones (ADR 0152).

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
5. a country that is the tags': first as written, then folded, or as one of the other's
   " & " list (`UK` and `UK & Europe`);
6. File, CD, CDr or SACD over vinyl and the rest;
7. a standard edition over a limited, special or promotional one of the same pressing;
8. the master's main release.

In steps 1 and 2 a catalog number on the first label weighs 2 and on another label 1, since
`CATALOGNUMBER` is the first label's (ADR 0128), and a matching barcode adds 1, so a release
with both beats one with either. Steps 3 to 5 match a release as Discogs has it now and then
as it has since been filled in or changed: the dump is newer than the tags, and releases gain
descriptions, fuller dates and wider regions. The owner approved this order on 2026-11-07: his
own (barcode or catalog number, format, main release) with step 1 split in two and `MEDIA`,
`DATE` and the country, which YATE copies from the release, before the format; the country
step on the same day, after the tuning found 13 wrong Exacts only the country told apart. Among releases that don't fit the
tracklist, the best rank (tracklist, plus `durationWeight` times the share of agreeing
lengths, a release without lengths counting half) is chosen, with the same tie-break.

**Step 7,** added on 2026-11-08 at the owner's request: a release with a format description
in `editionDescriptions` (Limited Edition, Numbered, Special, Deluxe or Club Edition, Promo,
Test Pressing, White Label, Unofficial Release) is passed over only when a release without
one is still tied and is the same pressing: the same first format, and the first label's
catalog number the same once folded or the release date the same to the month. Unscoped, the
step cost the titles-only run 3 points (61.6% to 58.6% same or twin, 233 to 253 wrong Exacts)
and placed after the main release 0.3: on small labels the main release is often the only
physical one and "Limited Edition", and the owner tagged it, where the release without the
description is a later download. Scoped by date and number without the format, a download the
label put out the same month still beat the limited CD (59.1%). As built, the tags run is
unchanged (95.6%, 30) and the titles-only run is 1,008 (61.8%) and 228 (14.0%).

**Choosing among a tie,** added on 2026-11-09 at the owner's request: Feels, titles only,
tied 12 CDs and went Exact on the main release, a repress, over the first pressing. Among
the releases the steps before the main release leave, the release shown first is the one
the owner's preferences put first: the country most of them share (each release weighs the
number of the others whose country fits its own, as in step 5, so `UK` and `US` count for
`UK & US`, and a lone Russian pressing weighs no more than one without a country), then no
Repress, Reissue or Remastered in its
formats, then the main release, then no description in `editionDescriptions`. They only
order the tie: the album is Exact only when step 8 alone leaves the same one release, and
otherwise Likely, still tied. The owner tagged a reissue, repress or remaster for 229 of
1,769 releases and the main release for 765, so letting the preferences decide made wrong
Exacts: on the titles-only run 61.5% and 251 (15.4%), against 61.5% and 212 (13.0%) as
built, from 61.8% and 228 (14.0%) before. Tried and rejected: CD and SACD over File and CDr
(62.2%, 245), the earliest year among the tied (58.5%, 340), and editions passed over beyond
one pressing (58.7%, 272).

The same day, a `DATE` of a year alone stopped counting in step 4's first part, as written:
Feels's files say `2005`, which only its represses and promos have as written, and the first
pressing's `2005-10-17` was passed over before the preferences saw it. A year alone now only
fits. The tags run went from 95.6% and 30 to 95.8% and 29.

The result per album is its tier, the chosen release, its tracks as files, each file's track,
and the other candidates best first.

### Thresholds and tuning

Every threshold is a constant in `MatchThreshold`. `TagCorpus --discogs-tuning` takes the
survey's cache of the watched folders (`.build/discogs-survey/files.jsonl`, read once, read
only), keeps the albums whose every track has one release id, hides the ids and matches them
against the real catalog, then again with the label, catalog number, barcode, date and media
hidden too, as an album YATE never tagged would be. Its report is `.build/discogs-tuning/report.txt`.

**The bar,** as the owner decided it on 2026-11-07: of the albums counted, at least 95% come
back Exact or Likely with the tagged release or a twin of it, and at most 2% Exact with a
release that is neither. A twin is equal to the tagged release in every tag the matcher
compares, as YATE writes them: the tracklist as files hold it, the first label's catalog
number, the first barcode, the release date, `MEDIA` and the country (`CatalogRelease.isTwin`).
Twins stay Exact. Left out, as albums nothing could fit (`releaseFit`):

- the tagged release isn't in the dump;
- the tagged release has another count than the files, or titles that aren't the files'
  (changed by the owner or on Discogs since the tagging);
- the album is Incomplete with the tagged release or a twin chosen, the files another count.

Albums whose tags name a date or `MEDIA` the tagged release no longer has, even as the
tie-break fits them (`tagsOutdate`), are counted, and listed as known misses when they miss.
The report gives each group on a line of its own, then the raw numbers as first measured.

Tuned on 2026-11-07 with the 20261101 dump, 1,741 albums, on this Mac (`--discogs-tuning`,
release build, one thread):

| Run | Not in the dump | Another count | Other titles | Kept at another count | Counted | Twins | Same or twin | Exact, neither | Known misses |
|---|---|---|---|---|---|---|---|---|---|
| As built, tags | 4 | 84 | 21 | 0 | 1,632 | 17 | 1,561 (95.6%) | 30 (1.8%) | 54 |
| As built, titles only | 4 | 84 | 21 | 0 | 1,632 | 7 | 1,005 (61.6%) | 233 (14.3%) | 0 |

**The bar is met** with the tags: 95.6% against 95%, and 1.8% against 2%. The titles-only run,
an album no tagger wrote a label, number, date, media or country for, is far from it, which is
what the Likely and Incomplete tabs are for. The Incompletes kept at another count are all
among the albums whose tagged release has another count, so that line is 0.

| Run, raw | Exact | Likely | Incomplete | No candidate | Same release, Exact or Likely | Exact, another release | Tagged release a candidate | Time |
|---|---|---|---|---|---|---|---|---|
| First, 3 s / 2%, the owner's steps only | 1,193 | 430 | 66 | 52 | 1,147 (65.9%) | 277 | 96.7% | 22.6 s, 13.0 ms an album |
| As built, tags | 1,447 | 211 | 66 | 17 | 1,554 (89.3%) | 56 | 98.8% | 7.2 s, 4.1 ms an album |
| As built, titles only | 1,073 | 484 | 68 | 116 | 1,005 (57.7%) | 251 | 92.4% | 2.0 s, 1.1 ms an album |

Where the files map to a track, the track is the one YATE's `DISCOGS_RELEASE_ORDINAL_POSITION`
(counted from 0) names for 13,027 of 14,092 files.

What moved the raw wrong Exacts: lengths out of the tie (277 to 223), the date and the spelled
number (to 146), `MEDIA` (to 81), and a fix to the catalog (51 albums with no candidate to 17):
the dumps write a release with no master as master 0, which the import kept, so no
master-less release had title keys. Then the first label's number, a barcode and a number
together, and `MEDIA` and `DATE` as Discogs has since filled them in (to 61), the country (to
57), and a `BARCODE` of "none" read as no barcode (to 56; it had looked up 49,818 releases with
"none" for one album, most of the run's time).

The 30 Exact with neither, from the report: 27 are known misses, where Discogs has changed
the tagged release's date or `MEDIA` since the tagging and another release has what the tags
say as written, which the tie-break takes before a fitted match. A Love Supreme: the tags say
`1965`, US; chosen 2552888 is `1965`, Canada; tagged 857505 is now `1965-01-00`, US. Bluesmith:
the tags' `Vinyl (LP,Album)` is chosen 11029266's format; tagged 738154 is now
`Vinyl (LP,Album,Stereo)`. Bitches Brew: the tags' `1970-06-00` is chosen 12032942's date;
tagged 37006 is now `1970-03-30`. The other 3 are changes to the tagged release's catalog
number or barcode: Back To Love (the tags' `BMI 022 CD`; tagged 137721 is now `BMI 022`),
Rushup Edge (the tags' `CAT189`; tagged 10594161 now has none), Live In Detroit (the tags'
barcode, which tagged 10033901 no longer has, so it isn't found at all). Of the 54 known misses,
the other 27 came back Likely.

A `BARCODE` or catalog number of "none" is no number: both tags and Discogs write it for a
release without one.

### Running it

`matchAlbums(_:catalogAt:choosing:progress:)` runs on a detached task with a catalog connection of its
own, opened for the call, since the system SQLite fails a connection whose file an import
replaced (ADR 0130). It checks for cancellation before each album and reports albums done of
the total: every album of a few, about 200 reports of thousands, since each redraws the window.
`readAlbumFiles` reports files read the same way.

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
