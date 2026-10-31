# 0008. Rebuild the index on a schema change, and key stats by path

- **Date:** 2026-10-30
- **Status:** accepted

## Context

The library database holds two kinds of data. The index (files, tracks, artists, albums, genres,
warnings, search) can always be rebuilt by rescanning. Plays, ratings and history (phase 7)
can't. Before the first release there are no migrations: stored data has one shape, and data
that doesn't match is discarded. A rebuild of the index, and every rescan, must still leave the
stats attached to the right tracks. The library is 43k files on a NAS, where the path is the
only identity a file has that costs nothing to read.

## Decision

Each part's `CREATE` SQL is its identity, stored in `schema_identity` when the part is built.
On open, a part whose stored SQL differs from the build's is rebuilt in one transaction: an
index mismatch drops every table except the stats tables and recreates the index, which the
next scan refills; a stats mismatch drops and recreates everything, discarding the stats.

The stats tables (`plays`, `ratings`, `history`) are keyed by the file's absolute path, as the
scanner stores it, with no foreign key to `files`. An index rebuild, a rescan, a file that
fails to read for a while, and a file removed and later restored all find their stats again
by path.

## Alternatives considered

- **`files.id` as the key** — rejected: IDs are reassigned by every index rebuild and by a file
  leaving and re-entering the index, which would orphan or misattach stats.
- **A content hash of the audio** — rejected: reading every file's audio on a NAS costs the
  whole library's size per full scan, and a tag edit (phase 11) mustn't change identity anyway.
- **Tag identity (artist, album, title, track)** — rejected: tags change, collide across
  editions, and are missing on some files.
- **A version number** — rejected by the pre-release rule; the SQL text can't drift from what
  was built, where a number can be forgotten.
- **Migrations** — rejected until the first release (AGENTS.md).

## Consequences

Moving or renaming a file, or remounting the NAS at a different path, loses its stats: the old
path's rows stay, unmatched, and the new path starts at zero. Phase 7 could offer to carry stats
across a move it detects (same tags and size, one path gone and one new), and a release that
needs a new mount path will need a path rewrite. Changing any index SQL costs one full rescan.
