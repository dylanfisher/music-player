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
- **The format and name.** The copy is gzipped with the system zlib (level 6, 1 MB chunks) to a
  hidden partial file named with a token of the write's own, then renamed to
  `library-YYYY-MM-DD.sqlite.gz`, the local day, so a snapshot cut short never has a snapshot's
  name. A second the same day, from Back Up Now, replaces the day's. One lock in the module
  takes every write in turn, since the daily job, Back Up Now and a restore can come from
  different queues; a leftover partial is deleted once it's an hour old, so another copy of the
  app's write under way is left alone. The writer lives in a module of its own, `Snapshot`,
  since Library has no use for zlib, and Discogs's gzip reader hashes, counts and resumes as it
  reads, which none of this needs.
- **Rotation**, the write's last step: of the day's snapshots, the newest 7 stay, then for each
  of the 4 ISO weeks before the oldest of them, that week's newest; of those written before a
  restore, the newest 3; the rest are deleted. Only files whose names parse as a snapshot's are
  ever deleted. A rotation that fails leaves the snapshot written and says so apart, and an
  entry whose size or date can't be read is left out of the list and logged.
- **When.** Once the launch's scans have ended, and every hour after, the app asks for the day's
  snapshot, which is written only when the folder has none of the day. The job runs on the
  watcher's scan queue (`LibraryWatcher.betweenScans`), so after a running scan or sync, paused
  or not, and before the next; with nothing watched, on a queue of its own. The scheduler is a
  class with a lock, not an actor, since its job runs synchronously on that dispatch queue. The
  last snapshot's time is the newest file's, so nothing is stored. A failure is logged at error
  and shown in Settings beside the time, not in a dialog nobody asked for. Runs that Bench
  measures, that draw a window PNG or that report the launch take none, so the reads don't add
  to what they measure. Back Up Now waits for a running scan to end, with a spinner.
- **The folder.** `library.snapshotFolder`, a local path; null is `Backups` beside the index in
  `~/Library/Application Support/MusicPlayer`. A folder inside a watched folder or inside the
  sync folder is refused in the config file, as the sync folder and the catalog are (AGENTS.md):
  the app writes there. A folder on a network volume is refused when a snapshot is written:
  that covers a watched share wherever it's mounted, which a path can't, and keeps snapshots off
  the NAS they'd be lost with; an external disk on this Mac is local, and works.
- **Restore.** Settings lists the snapshots with Restore…, which says the snapshot's plays,
  ratings and playlists replace the current ones. It unpacks the snapshot to
  `library.sqlite.restoring` beside the index, runs `PRAGMA integrity_check` on it, then
  snapshots the current index as `library-YYYY-MM-DD-before-restore-HHMMSS.sqlite.gz`, a name
  no day's snapshot takes, so restoring the day's own snapshot never overwrites it, and writes
  `restore.pending`. A snapshot that doesn't unpack whole or unpacks damaged, or a snapshot of
  the current index that fails, leaves nothing pending. The app then quits, and a `/bin/sh`
  child waits for the process to end and opens the app again with the same arguments.
- **The swap at launch**, before any connection opens the index, so none is left on a replaced
  file. Each copy of the app holds `library.sqlite.in-use` shared while it runs; the swap takes
  it exclusive without waiting, and while it's held, the restore waits for the next launch. The
  index's `.lock` and `.sync-lock` are held only for moments, so they can't say that. The swap
  moves the index aside as `library.sqlite.replaced-<stamp>` (`LibraryIndex.moveAside`, made
  `package` and given the reason) and the unpacked file into its place. When that move fails,
  the index goes back and the restore stays pending; when the index can't go back, the launch
  stops before opening any and says where it is. The replaced indexes are pruned to the newest
  3 only after the swap, so a launch stopped partway never prunes the index it moved. A marker
  left after the swap, with the unpacked file gone and an index in place, reads as applied. The
  app says when a restore was applied, or is waiting. A snapshot of an older shape takes the
  usual stale-part path, with its rescan question (ADR 0136).

## Consequences

- App state beside the index gains `library.sqlite.in-use`, and while a restore waits,
  `library.sqlite.restoring` and `restore.pending`; AGENTS.md's app state sentence says so, with
  the snapshot folder's rule. The music files boundary is unchanged: nothing here touches them.
- A restore loses what changed since the snapshot. The restored index's sync state is the
  snapshot's too, so the next sync reads the logs from where it was then, by ADR 0038's rules;
  nothing here changes them.
- A month of history costs 11 files of a compressed index, a few MB each for a 43k-track
  library.
