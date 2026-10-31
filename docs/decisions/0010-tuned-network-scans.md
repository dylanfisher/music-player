# 0010. Tune network scans to the NAS, and read while walking

- **Date:** 2026-10-30
- **Status:** accepted

## Context

The owner's library is 43k files (1 TB) on an SMB NAS over wired Ethernet. A scan reads about
9 KB per file in about 1.1 reads, so bandwidth isn't the limit: each file costs a few round
trips (open, read, close) and probably a disk seek on the NAS. ADR 0009 read network files on a
fixed 4 threads, and only after the whole walk had listed every folder. The best number in
flight depends on the NAS's disks and the network, which this repo can't see: no test or
benchmark may touch `/Volumes`.

## Decision

**Readers tuned from measured throughput.** On a network volume, `ReadConcurrency` sets how
many files are read at once. The scan measures windows of at least 0.25 s and 4 files per
reader, and passes each window's files/s and seconds per file to the controller, which reads no
clock and does no I/O. It starts at 4 and doubles while each doubling adds more than 15%. When
one doesn't, it settles on the level below, then holds for two windows at a time and probes a
quarter up (kept if 8% better) and a quarter down (kept unless 5% worse), so it drifts to the
fewest readers that reach the best throughput, which leaves the NAS room for playback. A held
level whose throughput falls below 60% of its estimate, or whose seconds per file double, means
the NAS got slower, perhaps from another client; the level halves and climbs again. It is
clamped to 2…64. A window in which a reader waited for the walk, or that spans or ends in a pause, is
dropped, since it says nothing about the NAS. `library.networkScanReaders` (null by default)
and `--scan … --readers <n>` fix the count instead, within 1…64. Local volumes stay at the core count:
there, parsing is the cost, so more threads than cores can't help and fewer only waste them.

**Read while walking.** `ScanPipeline` runs four lister threads, which walk depth-first and
queue each folder's changed files in listing order, and reader threads, which take files as they
arrive. Readers are threads pulling from that queue under a limit; `concurrentPerform` couldn't
change its count mid-scan. Raising the limit starts threads, and lowering it stops readers at
their next file. Four listers suffice: a listing is a round trip or two for about ten files that
cost several each to read, so a few stay ahead of many readers, and more would crowd the NAS
with directory requests. Each folder's files stay together in the queue, so the NAS reads
neighbouring files together. The safety rules from ADR 0009 are unchanged: nothing is removed
unless the walk finished, the folder is still on its device and lists something, and nothing
under an unreadable folder.

Batches are stored outside the lock that readers and listers share, one at a time, so a
12 ms store stalls only the reader that filled the batch.

**No read-ahead, no caching.** Tag reads open files with `F_RDAHEAD` off and `F_NOCACHE` on.

**A seam for latency.** The scan's file calls go through `ScanFileAccess`. `SimulatedNAS`
(tools tier) wraps the real one with a fixed latency per operation and a cap on how many it
serves at once. The benchmark scans 3,000 fixture files through it at 2 ms per operation and 16
at once: tuned readers took 2.56 s (1,176 files/s, readers 4→8→16→32→16) and a fixed 4 took
7.38 s (407 files/s), 2.9x slower. The best fixed level, 16, reached 1,437 files/s, so tuning
gave up 18% to finding it on a scan this short.

## Measured and rejected

- **Our own `getattrlistbulk` walk** — rejected. Interposing the syscalls showed
  `contentsOfDirectory(includingPropertiesForKeys:)` already uses `getattrlistbulk` and makes no
  stat per entry: a 202-entry folder took 4 `getattrlistbulk` calls, plus a `stat` and 3
  `getattrlist` on the folder itself, whatever its size. Calling it directly would save those
  four per folder, about 4k folders' worth on the NAS, against the reads' four or so per file,
  and they likely hit smbfs's attribute cache.
- **`F_RDAHEAD` and `F_NOCACHE`** — kept as free. On a cold APFS disk image, a 16 KiB read from
  the start of each of 120 8 MB files read 16.8 KB per file from disk with or without them, and
  2,000 small files read the same 10.9 KB per file in the same time (330–380 ms either way). The
  bench's parse and scan times didn't change. Uncached reads aren't kept, so reading the same
  file again goes to disk; pages already cached are still used. What they save on SMB is for the
  NAS checkpoint to show.
- **A larger first read** — rejected for now; it stays 16 KiB (`ByteReader.minimumReadBytes`,
  pinned by a test). On the fixtures, 1, 2 and 3 reads took 38,080, 4,826 and 58 files at
  16 KiB; 41,926 and 1,038 at 32 KiB; and nearly all one read at 64 KiB. But the fixtures average
  13 KB, so a larger read takes the whole file, which real 20–40 MB files don't allow. On those, a
  second read comes from an MP4 whose `moov` follows the audio, which no first read near the
  start reaches, and a FLAC whose PICTURE precedes its Vorbis comment, which a larger read only
  saves when the art is under that size, rarely for front covers. Each extra 16 KiB costs about
  0.14 ms on gigabit, against a round trip of a fraction of a millisecond plus a possible seek.
  Revisit with the NAS checkpoint's numbers.
- **Directory order** — kept: files are read in the order the volume lists them, folder by
  folder, rather than sorted by name, so the reads follow what the NAS returns.
- **A fixed count chosen for the owner's NAS** — rejected: it would be wrong on the next NAS or
  network, and wrong on this one while other clients load it.
- **Tuning local volumes too** — rejected: parsing on every core is already the best, and
  window noise would only move it away.

## Consequences

The NAS checkpoint compares tuning against fixed counts with `--readers`. The controller's
margins and window length were chosen against simulated curves (a NAS that saturates at 12,
one that degrades past 8, ±15% noise); a real NAS that is noisier, or whose best level changes
faster than a few seconds, may need them changed. A short scan spends a second or two finding
its level. Readers are threads of their own, up to 64 of them, each with a default stack.
