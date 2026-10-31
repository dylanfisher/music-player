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
many files are read at once. The scan measures windows of at least 2 s and 4 files per reader,
and passes each window's files/s and seconds per file to the controller, which reads no clock
and does no I/O. It starts at 16 and doubles unless a doubling gains 5% or less. When one
doesn't gain, it settles on the level below, then holds for two windows at a time and probes a
quarter up (kept if 8% better) and a quarter down (kept unless 5% worse), so it drifts to the
fewest readers that reach the best throughput, which leaves the NAS room for playback. A held
level whose throughput falls below 60% of its estimate, or whose seconds per file double, for
two windows in a row, means the NAS got slower, perhaps from another client; the level halves
and climbs again. It is clamped to 2…64. A window in which a reader waited for the walk, or
that spans or ends in a pause, is dropped, since it says nothing about the NAS: more readers
can't read files the walk hasn't found. `library.networkScanReaders` (null by default) and
`--scan … --readers <n>` fix the count instead, within 1…64. Local volumes stay at the core
count: there, parsing is the cost, so more threads than cores can't help and fewer only waste
them.

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
`--scan … --scan-io-hints none|rdahead|all` turns off both, keeps only `F_RDAHEAD` off, or
keeps both (the default), so the two can be compared on the NAS.

**What a scan shows.** The `--scan` progress line ends with the readers, how many of them are
idle waiting for the walk, the directories being listed and the files queued. The summary adds
the bytes and reads the scan asked for, per file; the time a file spent opening, reading and
in all; how long readers waited for the walk; and how many windows the controller judged or
dropped, and why.

**A seam for latency.** The scan's file calls go through `ScanFileAccess`. `SimulatedNAS`
(tools tier) wraps the real one with a latency per file operation, another per listing, an
optional log-normal disk delay per file, and a cap on how many requests it serves at once. Its
cost is per request, not per byte: a NAS serves a few kilobytes of tags in about the time it
serves a megabyte, and what scales is the number of requests in flight. Two benchmarks scan
fixture files through it:

- 3,000 files at 2 ms per operation and 16 at once: tuned readers take 2.00 s (1,506 files/s,
  readers 16), 3.6x faster than a fixed 4 (416 files/s). Before this change, starting at 4,
  tuned took 2.46 s.
- 2,000 files on a profile of the owner's NAS, cold: 10 ms per operation, a disk delay with a
  13 ms median and a long tail (σ 1.3), 45 ms per listing and 24 at once, so a file costs about
  60 ms and 16 in flight read about 16x as fast as one. Tuned readers reach 246 files/s
  (16→32→64→32), 89% of the best fixed level (32 readers, 276 files/s; 16 give 201 and 4 give
  51). The budget is 80% of the best fixed level, ending at 16 or more.

## Field data and the stall (2026-10-30)

The first cold scan of the owner's 43k files took 718.7 s at 60 files/s, with no failures, and
the trace `4→8→4→3→4→3→…→5→6→5→4→5 (held)`. Over SMB, `head -c 16384` read 21 files/s one at a
time and 371 files/s 16 at a time (`xargs -P`). A no-change rescan, which only walks, took 25.4
s, so the listers weren't what held it back, and the walk had queued 22k files by the halfway
mark. On a warm folder of 115 files, `--readers 16` read 568 files/s against `xargs -P 16` at
1,245 files/s, mostly fixed cost on a 0.2 s run, so readers overlap their reads in one process:
nothing in a reader holds a lock across I/O (the store runs outside the readers' lock, and a
reader makes no `FileManager` or main-thread call per file, and a `stat` only after a failed
read). Windows that waited for the walk are dropped rather than judged, so the trace's moves
were all on windows where every reader was busy.

What held the level down was the controller on a noisy, cold NAS. At 60 files/s, a window of
0.25 s or 4 files per reader held 15 to 30 files whose latency varies tenfold, a doubling had
to clear 15% in that noise, and one bad window halved the level. The fix starts at 16, judges
windows of at least 2 s, keeps doubling unless a doubling gains 5% or less, and backs off only
after two collapsed windows.

The simulation can't tell this apart from a NAS that really is flat past a few readers. With
each file also waiting 14 ms on one shared disk, the simulated cold scan reproduced the field
trace (4→8→16→8→4→8→4→5→6→5→4) at 48 files/s, and fixed 4, 8 and 16 readers all got 46–51
files/s. The NAS's monitor during the cold scan showed 3.8 MB/s out (about 70 KB per file on
the wire), 52.7 MB/s read from its volume (about 1 MB per file) and 6% CPU. The parser asks
for about 9 KB per file on the fixtures, in one 16 KiB read at the start of the file and rarely
a second, already one aligned read rather than several small ones. Whether the extra wire bytes
are smbfs rounding up, read-ahead the hints don't stop, or real files with large art before
their tags is for the summary's bytes per file to show beside the monitor's; the 1 MB per file
from disk is the NAS's own read-ahead or its SSD cache filling, which the Mac can't change.

To tell the two apart on the NAS, compare a fixed `--readers 4` and `--readers 16` scan of two
folders of a few hundred files each that no scan has read since the SSD cache was cleared (or,
failing that, run each twice and compare the second runs, so both are warm), with `sudo purge`
before each run so the Mac's own cache doesn't serve the files, and watch the progress line's
idle readers and queue. Run each `--scan-io-hints` choice the same way.

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
one that degrades past 8, ±15% and ±40% noise) and the cold scan above; a real NAS whose best
level changes faster than a few windows may need them changed. Windows of 2 s mean a scan
spends 4 to 8 s finding its level, and a scan shorter than one window stays at 16. Starting at
16 puts more requests on the NAS at once than 4 did, which a NAS shared with playback may
notice until the probes walk the level down. Readers are threads of their own, up to 64 of
them, each with a default stack.
