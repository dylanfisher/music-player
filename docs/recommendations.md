# Discogs lookup and recommendations

A plan for two features built on open data dumps:

1. **Discogs lookup.** Find a library album's Discogs release in a local copy of the Discogs
   catalog and offer its data as a tag edit the user confirms in the tag editor, written
   through `TagWriter` (ADR 0020).
2. **Recommendations.** Suggest albums and artists the owner doesn't have, from how records
   are connected in the Discogs catalog and from what other people listen to together.

Both run in a separate service, **music-recommender**, in its own repo at
`~/projects/music-recommender`, written in Rust and hosted on mbp2021. The player is its
client over the LAN. Not a phase yet. It replaces the API-based "Discogs lookup" item under
Later in [plan.md](plan.md).

## How it's built

```
 NAS (seed, 2026-11 only)       data.discogs.com, data.metabrainz.org
          │                                   │ monthly, checksummed
          ▼                                   ▼
 ┌─────────────────────── mbp2021: music-recommender ───────────────────────┐
 │ fetch → import → similarity → catalog database (local disk)              │
 │                                    │      Discogs API (ratings, token)    │
 │                          HTTP API, Bonjour, shared token                 │
 └────────────────────────────────────┬─────────────────────────────────────┘
                                      │ LAN
           ┌──────────────────────────┼──────────────────────────┐
     player (this Mac)          player (mbp2021)          player (mbp2015)
```

- **mbp2021 hosts it.** An M1 Max with 64 GB and 1.5 TB free. The dumps and the database live
  on its local disk, so imports and queries never read the NAS. Nothing runs on the 2015
  MacBook Pro except the player, which only sends requests.
- **The service owns all the third-party data.** It downloads the dumps, imports them,
  computes similarity, fetches Discogs ratings and answers queries. The player keeps no copy.
- **The player stays the only writer of music files.** The service suggests a lookup match;
  the player shows it in the tag editor and `TagWriter` writes it after the user confirms.
  The service never sees a music file.
- **Why Rust:** streaming parsers for about 150 GB of XML and JSON, sparse matrix work for the
  similarity step, and one binary to run as a service. It shares no code with the player; the
  HTTP API is the only contract between them.

## The dumps

Downloaded on 2026-11-06 to the NAS, outside the watched folders (`/Volumes/music/library` and
`/Volumes/music/dsd`). Each file was checked against its publisher's SHA-256 checksum. These
copies seed the service's first import: it copies them to mbp2021's disk, and the owner then
deletes the NAS folders. Later months download straight to mbp2021.

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

The service does the matching, from what the player sends about an album. The library has
43,382 tracks in 6,541 albums. The index doesn't store Discogs ids, and the tag reader doesn't
read `DISCOGS_RELEASE_ID`, though some files have it (39 of the 159 reference files). In order
of confidence:

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
3. **Ratings (Discogs API).** Average rating and have/want counts per release, fetched by the
   service with a Discogs personal token at 60 requests a minute, paced by the rate-limit
   headers. The local catalog supplies the ids, so no search is needed: about 2 hours, once,
   for the library's albums, then only the top few hundred candidates of a recommendation
   list. Cached in the service's database and refreshed slowly.

What the owner has and likes seeds the score: albums in the library, play counts, loved tracks
and ratings, which the player sends as a profile. Albums already in the library are never
suggested.

## The service

- **Fetch.** Once a month it checks the three sources for a newer dump, downloads it to
  mbp2021 within each source's rate limit (one request at a time to `data.discogs.com`, waiting
  out any `Retry-After`), and checks it against the published checksum before use. A failed
  or mismatched download is reported and the current database stays in use.
- **Import.** Reads each dump as a stream (the releases XML is about 80 GB uncompressed) and
  keeps only the fields above: releases, tracks, artists and their relations, labels, credits,
  masters, the MusicBrainz-to-Discogs links and ListenBrainz's per-user stats. It resumes after
  an interruption.
- **Similarity.** Computes the top neighbors per artist (and per release, if album-level
  proves worth it) from the ListenBrainz stats, and the catalog connections from Discogs.
- **Swap.** Each monthly rebuild writes a new database next to the current one and replaces it
  when complete, so queries never see a half-built catalog. Ratings carry over by Discogs id.
- **Answer.** An HTTP API on the LAN, advertised by Bonjour.

Its own AGENTS.md, conventions, tests and performance budgets live in its repo. The storage
engine (SQLite or another) is that repo's decision.

## Between the player and the service

- **Finding it.** The service advertises itself by Bonjour; the player finds it with
  Network.framework (available on macOS 12). An address in the player's `config.json`
  overrides discovery.
- **The token.** One shared token, set in the service's config and in each player's
  `config.json`, sent in an `Authorization: Bearer` header on every request. Decided by the
  owner on 2026-11-06. It is the player's first secret, so it needs an ADR; the player writes
  `config.json` as owner-only (mode 0600) while it holds a token, and never copies the token
  into the index, the state file, logs or the sync folder. The Discogs token is the
  service's, kept in its own config on mbp2021.
- **Requests**, in outline (the service's repo defines the API):
  - **Profile:** the player sends its library: album artist, title, track count and durations,
    catalog numbers, barcodes and Discogs ids where tagged, with play counts, loved tracks and
    ratings. The service keeps the latest profile and matches it to the catalog.
  - **Recommendations:** for the whole library or a seed artist or album, a list of albums
    and artists with a score, the signals behind it and a reason in words.
  - **Lookup:** for one album, ranked Discogs release candidates with their fields mapped to
    the player's tag fields.
- **Untrusted replies.** The player treats every reply as input from a LAN device (ADR 0025):
  a size cap, a timeout and typed errors. ADR 0025 gains rows for the client and the token.
- **When the service isn't answering**, the views say so and name the address tried; nothing
  falls back silently.

## In the player

- **Recommended** in the sidebar, laid out like Listening Stats (ADR 0102): a panel of cards
  over a list, here of albums and artists not in the library, each with its reason. A window
  for the full view with filters (style, era, label), like Year in Review's window.
- **Lookup in the tag editor:** a "Look Up on Discogs" action showing the candidates; choosing
  one fills the fields for the user to confirm, as any other tag edit.
- **The tag reader and the index** gain `DISCOGS_RELEASE_ID`, so tagged albums are sent with
  their ids.
- **Settings:** the service address override and the token.

## Build order

1. **Prototype (throwaway).** A script on this Mac over the data already unpacked in the
   scratchpad: artist similarity from the ListenBrainz all-time stats, the Discogs catalog
   connections, and top-50 lists for the whole library and a few seed artists with their
   reasons. The owner judges them, which settles the weighting and whether the catalog
   connections earn their import. Deleted afterwards.
2. **The service.** The music-recommender repo on mbp2021: fetch, import, similarity, swap and
   the HTTP API, with the lookup and recommendation requests.
3. **The player's client.** The token ADR and the ADR 0025 rows, Bonjour discovery, the
   profile, and `DISCOGS_RELEASE_ID` in the tag reader and the index.
4. **The player's views.** The Recommended source and window, and Look Up in the tag editor.
5. **Ratings.** The Discogs API fetch in the service, once the first four work without it.

## Decided

Answers from the owner on 2026-11-06:

| Question | Answer |
|---|---|
| Where it runs | mbp2021, with the dumps and database on its local disk |
| Repo | `~/projects/music-recommender`, separate from the player |
| Language | Rust |
| Discogs lookup | In the service; the player writes tags as before |
| Connection | HTTP on the LAN with one shared token, kept in config files |
| Discovery | Bonjour, with an address in `config.json` as the override |
| Discogs ratings | Yes, through the API with a Discogs token |
| Updates | Automatic monthly download, verify and rebuild |
| NAS copies | Seed the first import, then deleted by the owner |
| Prototype | A throwaway script first, judged before the repo is started |
| Where recommendations appear | A Recommended sidebar source like Listening Stats, and a window |
