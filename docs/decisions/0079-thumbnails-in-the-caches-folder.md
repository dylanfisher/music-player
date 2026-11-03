# 0079. The art column's thumbnails are kept in the Caches folder

- **Date:** 2026-11-03
- **Status:** accepted

## Context

Art was cached only in memory, 40 images in the art column, so every launch read each cover
from the NAS and decoded it again. Paging 30 screens of the art column sorted by title, at the
slow simulated NAS's latency, waited 2.87 s on the first launch and again on every later one,
with 292 reads each time. The real library has covers of 3000 px and more: decoding one to the
column's size takes 22 ms as JPEG and 123 ms as PNG here, and the 2015 MacBook Pro is slower.
Phase 32e asked whether to keep thumbnails in a table in the index or in files under
`~/Library/Caches/MusicPlayer`.

## Decision

`ThumbnailStore` (Artwork) keeps each thumbnail the column makes as a file in
`~/Library/Caches/MusicPlayer/Thumbnails`, or in the `--home` folder for tests and Bench:
JPEG at quality 0.9, or PNG when the image has alpha. A file's name is a 128-bit hash of the
track's path, the art's offset and length, the file's size and modification time as the index
has them, and the pixel size. A tag edit changes the size or time, so its new art is read
again, and a row needs no file access to find its thumbnail. A hit marks the file used.

The store keeps at most 100 MB and 20,000 files: a trim removes the least recently used, after
the first rows draw at launch and after each 10 MB written. A file that can't be read, decoded
or written is logged, up to 20 a session, and the cover is read from its file instead.

Only the art column uses it. The now-playing art and the art viewer show one cover at a time.

After the change, the second launch's 30 screens wait 0.57 s, about one frame of the
measurement's 60 Hz tick each, with 2 reads.

## Alternatives considered

- **A table in the index** — rejected: the index has a size budget (60 MB for the fixture
  library) that 100 MB of images would break, it's backed up with the user's stats, and the
  writes would share the reader's and the scanner's connection with the queries the window
  waits on. A cache that can be deleted belongs where macOS and backups expect caches.
- **Keying by a hash of the image's bytes** — rejected: computing it needs the bytes, which
  means reading the file from the NAS, the cost the store exists to save.
- **Keying by album** — rejected: the album's art can differ by track, and album IDs change
  when the index is rebuilt.

## Consequences

- Sorted by title, each track's row is an art run of its own and gets its own thumbnail, so
  a long scroll fills the store faster; the trim keeps it within its size.
- Clearing `~/Library/Caches/MusicPlayer` costs only the next launch's reads.
