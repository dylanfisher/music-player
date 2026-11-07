# 0130. The Discogs catalog is a SQLite file built by streaming the monthly dumps

- **Date:** 2026-11-07
- **Status:** accepted
- **Amends:** [0028](0028-network-folders-by-share.md) (a third folder found by share)

## Context

Phase 51's tagger matches library albums to Discogs releases. Its owner decided on 2026-11-07
that the matching reads a local catalog built from Discogs's monthly dumps, kept in a folder
on the NAS that music-recommender reads too, and that the system zlib may be linked. The
2026-11-01 set is four gzipped XML files, 12.6 GB in all, 11.4 GB of it releases, which
inflate to several times that. The window has to import a set with progress, be able to stop
it, and never see half a catalog, and the 2015 MacBook Pro has neither the disk nor the time
for a catalog of its own (51.13).

## Decision

### The settings

- `discogs.dumpsFolder`, null by default: `{"path": "/Volumes/music/discogs"}`, or on a
  share `{"share": "smb://nas/music", "path": "discogs"}`, found as 0028 finds a watched
  folder, through the sync folder's lookup, so a remount elsewhere still finds it. The app
  only reads it.
- `discogs.catalogPath`, null by default for `discogs.sqlite` in the data folder
  (`~/Library/Application Support/MusicPlayer`), or a file's absolute path. The config check
  refuses one inside a watched folder stored by path; the import checks the watched folders
  where they're found now, those on shares included, and refuses to start.
- The Settings window shows neither: 51d's window picks the folder, and the path matters
  only on a Mac short of space.

### The import

- **The set** is the newest date in the folder with `discogs_<date>_{labels,artists,masters,
  releases}.xml.gz` and a `discogs_<date>_CHECKSUM.txt` listing all four, so a month still
  downloading is passed over for the last complete one.
- **Streaming.** Each file is read once, 1 MB at a time, and inflated with zlib as it's
  read. Nothing is unpacked to disk. The inflated bytes are cut into batches of whole
  records, about 4 MB each, and `XMLParser` parses each batch as a document of its own, in
  an autorelease pool of its own. `XMLParser` autoreleases every string it hands its
  delegate and drains nothing until its parse returns: parsing a whole dump from an
  `InputStream`, as first built, held 1.8 GB by the 7 millionth release, and kept reading
  the file to its end after a stop. The dumps write each record on a line of its own, so a
  batch ends where a record's closing tag ends a line; text can't hold a tag, as XML
  escapes its `<`. A dump laid out otherwise fails to parse rather than being read wrong. The
  parser builds one record per top-level element and passes over the subtrees nothing is
  kept from (videos, notes, companies, profiles, aliases) without collecting their text.
- **The checksum** file is read and checked for all four names before anything is imported;
  each file's SHA-256 is taken from the bytes as they stream and compared at its end. A
  separate pass before the import would read the 12.6 GB from the NAS twice to learn
  nothing more: a file that doesn't match fails the import before the swap either way, and
  the smallest files go first so a bad set fails within the first minutes. zlib's own CRC
  catches a file cut short or damaged at the point it's read.
- **Writing.** The parse thread hands batches of 2,000 records to a writer on its own queue,
  two batches waiting at most, so the parser runs on while JSON is encoded and rows are
  inserted, and memory stays flat. Each batch is a transaction. The file has a memory
  journal and no syncs while it's written: nothing else opens it, and a failed import
  discards it whole. The system SQLite refuses `journal_mode = OFF` in its defensive mode.
  The indexes are built once the last row is in, which sorts each key table once, with the
  sort's temporary files on disk rather than in memory.
- **The swap.** The catalog is written as `<catalog>.importing` beside the old one, synced to
  disk, and renamed over it only when every file matched its checksum and the indexes are
  built. A reader opens the old catalog or the new one, never part of either. A failure, or
  a stop by cancelling the import's task, removes the new file, says why, and leaves the old
  catalog in use. The system SQLite fails a connection whose file was replaced with an I/O
  error rather than reading on, so the window opens the catalog again after an import.
- **Progress** is the compressed bytes read of the set's total, the record counts and the
  stage, a few times a second off the main thread; the index build is the last step.

### The schema

One row per label, artist, master and release, with what the matcher compares and the
mapping writes: for a release its id, master id and whether it's the main release, title,
country and release date as columns, and its artists (id, name, ANV, join), labels with
catalog numbers, formats with descriptions, genres, styles, barcodes, credits and tracklist
as one JSON object. A track keeps its position as written, title, duration in seconds,
artists and credits, and its kind: an index track has sub-tracks, a heading has no position
and no duration, as the dumps have no type for either. Artists keep their name variations,
labels their name, masters their main release, title, year, artists, genres and styles.

The lists are JSON because the catalog is only ever read a record at a time: 51c fetches a
few candidates per album and needs all of each. Tables for tracks and credits would hold a
few hundred million rows, with their own ids and indexes, for no query that reads them on
their own. A track's keys are one letter and its empty lists are left out, since tracks are
most of the file. 51c adds columns, such as a track count, when a query needs one.

The keys are their own tables, indexed after the load: `title_keys` (artist key, title key)
for every master and for every release with no master, `barcode_keys` and `catno_keys`
(label key, catalog number key) for every release.

A `catalog` row holds the dump's date and the schema's SQL. A catalog whose SQL isn't this
build's is refused as built by another version, and the window offers an import; nothing
migrates it.

### The folding

`CatalogKey.fold`, the rules music-recommender's coverage count used on 2026-11-06:
lowercased, accents and a leading "The" dropped, `&` as "and", a `(2)` suffix removed, and
everything but letters and digits removed; a title also loses bracketed edition words such as
"(Remastered)" and "[Deluxe Edition]". An artist credit gets a key for each name, for all of
them run together, and for all of them joined by "and", so the library's "A & B" finds
Discogs's [A, B]. Barcodes and catalog numbers fold the same way, so "0 7464-63628-2 2" and
"074646362822" are one, and a catalog number of "none" is no number. 51c folds the library's
tags with the same functions.

Rejected: building the catalog in music-recommender and reading its database. The owner
decided each program builds its own from the one copy of the dumps.
