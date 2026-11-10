# 0189. Discogs covers are kept on disk

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0172](0172-every-picture-and-bulk-covers.md) (Get Artwork),
  [0140](0140-discogs-cover-art.md) (Discogs covers), [0079](0079-thumbnails-in-the-caches-folder.md)
  (the thumbnails' folder), [0138](0138-the-discogs-api-client.md) (the client's pacing)

## Context

The owner asked, on 2026-11-10, what a quit or a crash halfway through Get Artwork's "Getting
covers" loses. All of it: the covers are held in memory and written as one batch at the end
(ADR 0172). The release JSON is in the index's `discogs_cache`, but each image is a second
paced request, so 4,000 albums take a little over 2 hours, and a run after a crash fetched
every image again.

## Decision

- **`CoverStore` (Discogs)** keeps each image that passes `Cover(checking:)` as a file in
  `~/Library/Caches/MusicPlayer/Discogs Covers`, or the `--home` folder, named by a hash of its
  image URL. `DiscogsAPI.cover(release:)` looks there before the image request, so Get Artwork
  and Apply's covers both use it. A kept file is checked again as it's read; one that fails is
  removed and fetched again.
- **Capacity:** 1 GB, least recently used first, about 7,000 of Discogs's 600-pixel covers.
  A run larger than that loses only its oldest covers to a trim.
- **`CacheFolder` (Primitives)** is the folder, hashing, trim and failure count the thumbnails
  and spectrograms had each written, now the third use. Its file names hash the same key as
  theirs did, so the files already stored are still found.
- **The writes stay one batch.** Undo Tag Edit puts back the whole run, as before.

## Alternatives considered

- **Writing the covers in chunks as they arrive.** Rejected: a chunk an undo entry, and the
  journal keeps 50, so a large run couldn't be undone at once; one entry that grows across
  chunks would change the journal's crash-safe ordering when another edit lands between them.
- **A table in the index.** Rejected for the reasons ADR 0079 gives: the index has a size
  budget and is in every snapshot.

## Consequences

- A run after a crash makes no request for an album whose release JSON and cover are kept; the
  writes then take what they always took.
- The covers are still held in memory until the batch is written, as before.
- Clearing the Caches folder costs only the covers being fetched again.
