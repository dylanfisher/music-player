# 0142. Daily snapshots of the library index, and restoring one

- **Date:** 2026-11-08
- **Status:** accepted
- **See also:** [0023](0023-failure-table.md) (moving an unreadable index aside),
  [0038](0038-sync-logs.md) (the sync folder), [0130](0130-discogs-catalog.md)
  (the Discogs catalog)

## Context

The library index holds what no scan can make again: plays, skips, ratings, playlists and the
play history. A damaged disk, a bad sync or a mistaken bulk edit loses them, and the only copy
was the live file. Phase 53.6 and 53.7 ask for a dated copy each day and a way back to one.

## Decision

- **What is kept.** Only the library index. The Discogs catalog is imported again from the dumps
  instead: it is several GB, and nothing in it is the owner's own.
- **The copy.** `VACUUM INTO` a temporary file in the snapshot folder, on a connection of its
  own (`LibraryIndex.copy(to:)`). A file copy of a live WAL database can take the main file and
  the log at different moments, and misses commits still in the log; `VACUUM INTO` reads one
  transaction's view, log included, writes a compacted file, and leaves the index as it was.
  macOS 12 ships SQLite 3.37; it needs 3.27.
- **The format and name.** The copy is gzipped with the system zlib (level 6, 1 MB chunks) to
  `library-YYYY-MM-DD.sqlite.gz.partial`, then renamed to `library-YYYY-MM-DD.sqlite.gz`, the
  local day, so a snapshot cut short never has a snapshot's name. A second the same day, from
  Back Up Now, replaces the day's. The writer lives in a module of its own, `Snapshot`, since
  Library has no use for zlib, and Discogs's gzip reader hashes, counts and resumes as it reads,
  which none of this needs.
- **Rotation.** After each snapshot: the newest 7 stay, then for each of the 4 ISO weeks before
  the oldest of them, that week's newest; the rest are deleted. Only files whose names parse as
  a snapshot's are ever deleted; anything else in the folder stays.
- **When.** Once the launch's scans have ended, and every hour after, the app asks for the day's
  snapshot, which is written only when the folder has none of the day. The job runs on the
  watcher's scan queue (`LibraryWatcher.betweenScans`), so after a running scan or sync, paused
  or not, and before the next; never during one. The last snapshot's time is the newest file's,
  so nothing is stored. A failure is logged at error and shown in Settings beside the time, not
  in a dialog nobody asked for. Runs Bench measures take none.
- **The folder.** `library.snapshotFolder`, a local path; null is `Backups` beside the index in
  `~/Library/Application Support/MusicPlayer`. A folder inside a watched folder or inside the
  sync folder is refused, as the sync folder and the catalog are (AGENTS.md): the app writes
  there. A share isn't offered: it would need `ShareLookup`'s finding, and a snapshot on the NAS
  goes with the NAS.
- **Restore.** Settings lists the snapshots with Restore…, which says the snapshot's plays,
  ratings and playlists replace the current ones. It unpacks the snapshot to
  `library.sqlite.restoring` beside the index, runs `PRAGMA integrity_check` on it, then
  snapshots the current index (after the check, since on the chosen snapshot's own day that
  snapshot would be overwritten), writes `restore.pending`, and relaunches once the process has
  ended. The next launch, before any connection opens the index, moves the index aside as
  `library.sqlite.replaced-<stamp>`, pruned to the newest 3 as the unreadable ones are, and
  renames the unpacked file into its place. Swapping at launch leaves no open connection on a
  replaced file. A snapshot that doesn't unpack whole, or unpacks damaged, is refused with
  nothing replaced. A snapshot of an older shape takes the usual stale-part path, with its
  rescan question (ADR 0136).

## Consequences

- AGENTS.md's "app state lives in the SQLite index" gains its snapshots in the snapshot folder.
  The music files boundary is unchanged: nothing here touches them.
- A restore loses what changed since the snapshot. The restored index's sync state is the
  snapshot's too, so the next sync reads the logs from where it was then, by ADR 0038's rules;
  nothing here changes them.
- A month of history costs 11 files of a compressed index, a few MB each for a 43k-track
  library.
