# 0009. Scan rules that never read a missing volume as deleted files

- **Date:** 2026-10-30
- **Status:** accepted
- **Amended by:** [0023](0023-failure-table.md): the failure table, and the failures phase 14a
  changed how this reports. [0040](0040-gentle-network-rescans.md): network folders aren't
  rescanned at launch. [0124](0124-drop-files-and-the-library-folder.md): files dropped on the
  window are rescanned, or their folders watched.

## Context

The scanner keeps the index in line with 43k files, mostly on a NAS over SMB that can be
unmounted at launch or vanish mid-scan. A naive rescan that finds nothing removes the whole
library. Reads on the NAS are slow, so a rescan with no changes must read no file, and a scan
must not starve playback reading from the same share. FSEvents doesn't report SMB changes.
Idle CPU is budgeted at about zero.

## Decision

**Walk and read.** The walk lists each directory with `contentsOfDirectory` and prefetched
resource values, which come from `getattrlistbulk` with the listing: one stat per entry, in bulk.
Hidden entries (`.DS_Store`, AppleDouble `._` files) and symbolic links are skipped, the latter
reported. Only files with an audio extension count. A file whose path, size and mtime match the
index is unchanged; everything else is read as the walk finds it, on the core count's threads
locally and a tuned number on a network volume (found with `volumeIsLocal`; ADR 0010), and
stored 500 to a transaction.

**Nothing is removed under anything the scan couldn't see.** Files are removed only after a
walk that finished, when the folder is still the same directory on the same device (`st_dev`)
as at the start, and never at or under an entry that couldn't be listed or stat'ed. A missing
folder, one that lists nothing while the index holds its files (an empty mount point), and one
that vanished or changed device during the scan are reported and keep the index as it was. A
reader whose file is unreadable checks the folder; if it's gone, reading stops.

**An unreadable file keeps its earlier track.** A read failing with `unreadable` (I/O, not a
damaged file) records the failure but keeps the track and its old size and mtime, and such a
file is read again on every scan until it reads. A structural failure replaces the track,
because the file on disk is what's broken.

**Watching.** Local folders are scanned whole at launch, then by the subtrees FSEvents reports,
collected for 2 s; dropped events or a moved root rescan the whole folder. Network folders are
polled `pollIntervalMinutes` after launch, or at launch when the index holds nothing for them
(ADR 0040), and then `pollIntervalMinutes` after each scan ends, by one one-shot timer for
the earliest due poll. Files outside every watched folder are removed at launch. The playback
hook keeps network scans from starting, and pauses a running one, while a track starts, and
while playing if `library.pausePollingDuringPlayback` is on.

**One spelling for paths.** Swift compares strings by canonical equivalence and SQLite compares
bytes, including the range query that finds a folder's files. APFS lists names decomposed
(NFD) even for a folder created precomposed, so enumeration, `realpath` and FSEvents agree
with each other, and the other spelling still opens the file. Only a configured root can
differ, because Settings may hold it precomposed, so `canonicalPath` decomposes it and trims
trailing slashes, once, wherever a root enters the library. The test
`rootSpelledPrecomposedOrDecomposedIsOneFolder` shows both spellings of a root giving one set of
paths. Names a network share lists precomposed are stored as listed.

## Alternatives considered

- **`FileManager.enumerator`** — rejected: one error handler for the whole walk makes it hard
  to tell which subtree went unseen, and it can't be paused between directories.
- **`fts` or `readdir` plus `lstat`** — rejected: a stat per file is a round trip per file on
  SMB, where the bulk listing is one per batch.
- **Refusing to remove more than some share of a folder in one scan** — rejected: it blocks real
  deletions and still misses a partial vanish; the device and listing checks are exact.
- **A periodic timer that checks what's due** — rejected: it fires while nothing is due, against
  the idle budget.

## Consequences

A no-change rescan of the fixture library takes under a second locally; on the NAS it costs
one listing round trip per directory batch. A folder emptied on purpose keeps its files until it
is removed from Settings. A dead SMB mount that lists directories as empty without an error
would read as deletions; the device check catches an unmount, not that. `MusicPlayer --scan`
on a folder that isn't watched refuses to write to the app's own index, since the app would
remove those files at its next launch; `--db <file>` scans into a separate index.
