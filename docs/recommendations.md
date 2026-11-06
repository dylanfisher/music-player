# Discogs lookup and recommendations

A plan for two features built on open data dumps instead of web APIs:

1. **Local Discogs lookup.** Find a library album's Discogs release in a local copy of the
   Discogs catalog and offer its data as a tag edit the user confirms in the tag editor,
   written through `TagWriter` (ADR 0020).
2. **Recommendations.** Suggest albums and artists the owner doesn't have, from how records
   are connected in the Discogs catalog and from what other people listen to together.

Not a phase yet. It replaces the API-based "Discogs lookup" item under Later in
[plan.md](plan.md): a local copy needs no Discogs token, so the no-secrets rule holds, and a
lookup makes no network connection.

## The dumps

Downloaded on 2026-11-06 to the NAS, outside the watched folders (`/Volumes/music/library` and
`/Volumes/music/dsd`). Each file was checked against its publisher's SHA-256 checksum.

| Folder | File | Size | License | Dump date |
|---|---|---|---|---|
| `/Volumes/music/discogs` | `discogs_20261101_artists.xml.gz` | 478 MB | CC0 | 2026-11-01 |
| | `discogs_20261101_labels.xml.gz` | 88 MB | CC0 | 2026-11-01 |
| | `discogs_20261101_masters.xml.gz` | 605 MB | CC0 | 2026-11-01 |
| | `discogs_20261101_releases.xml.gz` | 10.6 GB | CC0 | 2026-11-01 |
| | `discogs_20261101_CHECKSUM.txt` | | | |
| `/Volumes/music/musicbrainz` | `mbdump.tar.bz2` (core data) | 7.7 GB | CC0 | 2026-11-04 |
| | `SHA256SUMS` | | | |
| `/Volumes/music/listenbrainz` | `listenbrainz-statistics-dump-20261101-000003.tar.zst` | 24.9 GB | CC0 | 2026-11-01 |
| | `listenbrainz-feedback-dump-20261106-021503.tar.zst` | 81 MB | CC0 | 2026-11-06 |

Sources: `https://data.discogs.com/` (monthly, around the 1st) and
`https://data.metabrainz.org/pub/musicbrainz/` (MusicBrainz twice a week, ListenBrainz monthly).
Discogs rate-limits downloads: a few requests in quick succession got an HTTP 429 with
`Retry-After: 2750`. MetaBrainz served about 2.6 MB/s.

### Discogs

Gzipped XML in the shape of the Discogs API. Counts from a full pass over each file:

| Dump | Records | What we use |
|---|---|---|
| artists | 10,284,281 | Name, real name, name variations; aliases (657,437 artists have them), members (674,232), groups (1,387,732) |
| labels | 2,436,770 | Name, parent label, sublabels |
| masters | 2,608,936 | Main release, artists, year, genres, styles |
| releases | 19,575,942 | See below |

A release has artists and labels with ids, catalog numbers, credits with roles
(`Written-By [All Tracks By]`, `Lacquer Cut By`), formats with quantity and descriptions,
genres, styles, country, a release date with unknown parts as `00` (`1999-03-00`), a master id,
a tracklist and identifiers (barcodes, matrix and runout). Across all releases:

- 182M tracks, about 9 a release. 95.4M (52%) have a duration (`4:45`), so duration matching
  covers about half the catalog.
- 6.7M barcode identifiers, on at most a third of releases.
- 1.7M tracks with sub-tracks (a heading with its movements or a medley's parts).
- Positions follow the medium: `A`, `B1`, `C2` on vinyl, and forms like `CD2-4` elsewhere.
- Discogs has 15 genres and 756 styles. Every release has a `master_id` element; how many are
  empty is not yet counted.

The dumps have **no community data**: no ratings, have/want counts or collections. Those are only
in the API.

### MusicBrainz

The core dump holds MusicBrainz's URL relationships, which link artists, release groups and
releases to their Discogs pages. That is how ListenBrainz data, keyed by MusicBrainz ids
(MBIDs), joins the Discogs data. The join needs ten tables of the core dump, about 6 GB
unpacked: `url` (the Discogs ones match `discogs.com/(artist|master|release)/<id>`),
`l_artist_url`, `l_release_group_url` and `l_release_url` (entity, then url), `artist`,
`release_group`, `release` and `artist_credit_name` for MBIDs and names, and `link` and
`link_type`, which the URL match makes unnecessary. Counts:

| Entity | In MusicBrainz | Linked to Discogs |
|---|---|---|
| Artists | 3,032,671 | 1,281,511 (to a Discogs artist) |
| Release groups | 4,621,126 | 351,994 to a master; 1,501,479 counting a linked release |
| Releases | | 1,898,079 (to a Discogs release) |

3,556,411 URLs in MusicBrainz point at Discogs.

The `mbdump-derived` dump (503 MB) has MusicBrainz user ratings and tags, but it is
CC BY-NC-SA, not CC0, and its ratings are sparse. Not downloaded.

### ListenBrainz

The statistics dump has each listener's top artists, releases and recordings with listen
counts and MBIDs, one JSON line per user, for nine periods: all time, year, half year,
quarter, month, week, and this year, month and week. It also has daily and listening
activity per user, which isn't useful here.

```json
{"user_id":1,"data":[{"listen_count":4298,"artist_name":"Wax Tailor","artist_mbid":"c24b47a1-…"}, …]}
{"user_id":1,"data":[{"listen_count":1699,"release_name":"Filling Up the City Skies","release_mbid":"dda07cd4-…","artist_mbids":["3a07764c-…"], …}, …]}
```

| Stat | All time, unpacked | All nine periods |
|---|---|---|
| Artists | 4.2 GB | 13.3 GB |
| Releases | 17.2 GB | 56.4 GB |
| Recordings | 25.3 GB | 93.9 GB |

The all-time artists cover 101,313 users and 702,983 artist MBIDs. 284,852 artists have 5 or
more listeners, the least that co-occurrence can say much about. 406,579 artists link to
Discogs through MusicBrainz, 196,884 of them with 5 or more listeners. Release stats join to
Discogs releases through `l_release_url`, so album-to-album similarity is possible too.

The feedback dump (loved and hated tracks) is of little use: of 6,129,610 rows only 3,534 carry
a recording MBID. The rest have a MessyBrainz id or `None`.

Not downloaded: the 240 GB full listen history (the statistics dump has its totals), MLHD+
(2023) and the 2020 labs datasets. ListenBrainz's precomputed similar-artist data is only
served by its online API, so similarity is computed locally from the statistics dump.

## Matching the library to Discogs

The library has 43,382 tracks in 6,541 albums. The index doesn't store Discogs ids, and the tag
reader doesn't read `DISCOGS_RELEASE_ID`, though some files have it (39 of the 159 reference
files). In order of confidence:

1. **A Discogs release id in the tags.** No matching needed. The tag reader and the index gain
   the field.
2. **Barcode** (629 albums) or **catalog number with label** (1,811 albums). Usually one
   release, or a few editions to choose between.
3. **Artist, album title, track count and durations.** Search masters by folded artist and
   title, then rank the master's releases by track count, durations where Discogs has them,
   then format, country and year. Discogs positions, headings, sub-tracks and `Artist (2)`
   name suffixes are folded before comparing.

A match is a suggestion. The user confirms it in the tag editor, and only then does
`TagWriter` write the release's fields, including its Discogs id, so the next lookup is case 1.

### Coverage

Measured on 2026-11-06 by exact match of folded names: lowercased, accents and a leading
"The" dropped, `&` as "and", `Artist (2)` suffixes and edition words in brackets ("Remastered",
"Deluxe Edition", "SACD") removed, punctuation and spaces removed. These are lower bounds;
fuzzy matching and track counts will find more.

| Library | Count | Found |
|---|---|---|
| Albums (127 by Various Artists or with no artist) | 6,541 | |
| … as a Discogs master by artist and title | | 2,447 (37%) |
| … as a MusicBrainz release group | | 2,668 (41%) |
| … and that group linked to Discogs | | 2,244 (34%) |
| … and its artist in ListenBrainz with 5+ listeners | | 2,119 (32%) |
| Artists (album and track artists, including "A feat. B" credits) | 4,526 | |
| … in MusicBrainz by name | | 3,421 (76%) |
| … linked to Discogs | | 3,248 (72%) |
| … linked to Discogs and in ListenBrainz with 5+ listeners | | 2,571 (57%) |
| … among Discogs master artists by name | | 3,138 (69%) |

Artist-level similarity reaches more of the library than album-level, so recommendations
start from artists.

## Recommendations

Three independent signals, each useful without the others, combined into one score per
candidate album or artist:

1. **Catalog connections (Discogs).** Shared credits (producers, engineers, session players),
   the same label or a sublabel within a few years, aliases, groups and members, and
   overlapping styles weighted by how rare each style is. Explainable: "Produced by X, who
   produced 4 albums you have."
2. **Listening together (ListenBrainz).** Artist-to-artist similarity from co-occurrence in
   listeners' top-artist lists, weighted so artists everyone plays don't dominate. Joined to
   Discogs through the MusicBrainz links.
3. **Ratings (Discogs API, optional).** Average rating and have/want counts per release. The API
   without a token allows about 25 requests a minute and looks up by id only, which is enough
   since the local catalog supplies the ids: about 4½ hours, once, for the library's albums,
   then fetching only the top few hundred candidates of a recommendation list. It is the app's
   first outbound internet connection, so ADR 0025 gains rows for it.

What the owner has and likes seeds the score: albums in the library, play counts, loved tracks
and ratings from the index. Albums already in the library are never suggested.

## Storage and import

- The derived data goes in its own SQLite file, not `library.sqlite`: the trimmed catalog
  (releases, tracks, artists, labels, credits, masters, the MusicBrainz links) and the
  precomputed similarity tables. Only the fields above are kept.
- The import reads each dump as a stream (the releases XML is about 80 GB uncompressed), runs off
  the main thread, and can resume after an interruption.
- A monthly Discogs dump replaces the catalog file whole. Pre-release, stored data has one
  shape, so a schema change means a fresh import.
- On the 2015 MacBook Pro a full import will likely take hours. It may be built on a faster Mac
  and the file copied over; that's a performance budget row once measured.

## Open questions for the owner

- **Reading the NAS.** AGENTS.md says no tool touches the NAS. The import only reads these dump
  folders, but the boundary needs an explicit exception and an ADR.
- **Where the derived database lives**, and how big it may be on the 2015 MacBook Pro.
- **The Discogs API for ratings:** wanted at all, and with a user-supplied token (a secret, so
  how it's stored) or without one at the slower rate.
- **Where recommendations appear:** a library-browser section, the Now Playing view, or a
  separate window.
