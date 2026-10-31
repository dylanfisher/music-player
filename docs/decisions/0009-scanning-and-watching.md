# 0009. Scan rules that never read a missing volume as deleted files

- **Date:** 2026-10-30
- **Status:** accepted

## Context

The scanner keeps the index in line with 43k files, mostly on a NAS over SMB that can be
unmounted at launch or vanish mid-scan. A naive rescan that finds nothing removes the whole
library. Reads on the NAS are slow, so a rescan with no changes must read no file, and a scan
must not starve playback reading from the same share. FSEvents doesn't report SMB changes.
Idle CPU is budgeted at about zero.

## Decision

**Walk, then read.** The walk lists each directory with `contentsOfDirectory` and prefetched
resource values, which come from `getattrlistbulk` with the listing: one stat per entry, in bulk.
Hidden entries (`.DS_Store`, AppleDouble `._` files) and symbolic links are skipped, the latter
reported. Only files with an audio extension count. A file whose path, size and mtime match the
index is unchanged; everything else is read on a fixed number of threads (the core count
locally, 4 on a network volume, found with `volumeIsLocal`) and stored 500 to a transaction.

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
polled at launch and then `pollIntervalMinutes` after each scan ends, by one one-shot timer for
the earliest due poll. Files outside every watched folder are removed at launch. The playback
hook keeps network scans from starting, and pauses a running one, while a track starts, and
while playing if `library.pausePollingDuringPlayback` is on.

## Alternatives considered

- **`FileManager.enumerator`** — rejected: one error handler for the whole walk makes it hard
  to tell which subtree went unseen, and it can't be paused between directories.
- **`fts` or `readdir` plus `lstat`** — rejected: a stat per file is a round trip per file on
  SMB, where the bulk listing is one per batch.
- **Overlapping the walk with reading** — deferred: simpler to reason about removal after a
  complete walk, and the fixture library scans in 3 s. Revisit if the NAS checkpoint shows the
  walk and the reads each take long enough to overlap.
- **Refusing to remove more than some share of a folder in one scan** — rejected: it blocks real
  deletions and still misses a partial vanish; the device and listing checks are exact.
- **A periodic timer that checks what's due** — rejected: it fires while nothing is due, against
  the idle budget.

## Consequences

A no-change rescan of the fixture library takes under a second locally; on the NAS it costs
one listing round trip per directory batch. A folder emptied on purpose keeps its files until it
is removed from Settings. A dead SMB mount that lists directories as empty without an error
would read as deletions; the device check catches an unmount, not that. Running
`MusicPlayer --scan` on a folder that isn't watched adds files that the app removes at its next
launch.
