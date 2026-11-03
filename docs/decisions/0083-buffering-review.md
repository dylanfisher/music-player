# 0083. Buffering: keep the 8 s ring, and let a refill give way to a waiting seek

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0029](0029-longer-decode-bursts-and-a-sleeping-control-thread.md), [0078](0078-time-to-sound.md)

## Context

Phase 35.4 asked how a track is read and decoded, whether reading whole files, reading the next
track ahead or keeping played regions would serve the 2015 MacBook Pro (16 GB, 2 cores) and the
NAS better, and to change buffering only where a bench shows it pays against the phase 32
budgets: time to sound, seek to first sound, and soak memory.

## How it works today

All of this runs on `DeviceOutput`'s control thread; the IO proc only copies from the ring
buffer (`HALRender`, `RingBuffer`), and nothing here changes that.

- **Reading.** PCM goes through `ExtAudioFile`, decoded 32,768 frames a call (0.74 s at
  44.1 kHz, 0.17 s at 192 kHz); AudioToolbox picks its own read sizes, and the SMB client turns
  them into reads of up to 1 MB that it reads ahead and keeps while the file is open, which is
  what the bench's `FileLatency` charges for (0078). DSD is read by `DSDReader` in its file's
  blocks.
- **How far ahead.** An 8 s ring buffer per stream (4, 16 and 64 MB at 44.1, 192 and 768 kHz),
  refilled to full once half empty, so a refill is 4 s of audio and the other 4 s cover a NAS
  read that stalls (0029). A load or a seek queues 0.5 s before the device starts or carries
  on, and the next pass fills the rest, 7.5 s.
- **The next track.** It is opened when the engine names it, seconds before it plays. With the
  same rate and channels it is decoded into the ring straight after the current one, so it
  starts reading up to 8 s before the boundary and plays without a gap. With another format,
  its first 0.5 s is decoded into memory while the ring drains, and the switch copies it in.
- **What's kept.** Every track with audio in the ring keeps its file open, so a seek back into
  one rewinds its decoder instead of opening the file again (0078). No decoded audio is kept
  once played; the SMB client keeps what it read of open files.
- **A seek.** The control thread discards the ring (the IO proc drops it at its next cycle),
  seeks the decoder, queues 0.5 s and lets the next pass fill the rest. Commands wait for the
  pass they arrive in, and a pass could be in a refill of up to 7.5 s.

Measured on the build Mac, null device, the slow simulated NAS (23 ms an open, 10 ms a block)
and local files, median of 5:

| Case | NAS | Local |
|---|---|---|
| Seek while the track is decoded, to first sound | 8.7 ms | 6.4 ms |
| Seek after decoding moved on, to first sound | 5.1 ms | 7.9 ms |
| A seek 20 ms after another, 24/192 FLAC, to playing from it, before this change | 204 ms | 146 ms |
| The same, after | 4.3 ms | 3.4 ms |

The third row is the scrub the owner does when clicking along the bar: the second click lands
in the refill after the first, and on 24/192 FLAC that refill is about 4.7 MB to read and 7.5 s
to decode. On the 2015 Mac, with slower cores and a real NAS, it waits longer.

## Decision

**A refill gives way to a waiting command.** `fill` without a byte limit checks, after each
chunk it writes, whether a command is waiting, and if so returns; the run loop does the command
and the next pass carries on filling. Every pass still writes at least one chunk, so commands
arriving one after another (a volume drag) slow a refill down but can't stop it. The 0.5 s a
load or seek queues is not cut short. The check takes the control thread's lock once a chunk,
which the IO proc never takes. Bench: `a seek 20 ms after another`, 25 ms on Apple Silicon and
an estimated 80 ms on the old Mac, the same as the other seeks.

**Everything else stays.** The ring's size and refill point stay as 0029 set them, so playback
CPU and the soak's memory don't move.

## Alternatives considered

- **Reading the whole file into memory at the start.** Rejected. A 24/192 FLAC of five minutes
  is about 190 MB, and a DSD128 file more; the soak allows 10 MB of growth and the old Mac 250 MB
  resident. It reads the whole file from the NAS in a burst at every track change, while the
  browser may be reading art and a scan rows from the same share. Gapless gains nothing, since
  the next track already starts decoding seconds early. Seeks would still pay the decoder's own
  seek, which is the cost left after this change.
- **Reading the next track ahead near the end.** Already done: it is opened when named and
  decoded up to 8 s before the boundary, or its start is decoded ahead of a format switch.
- **Keeping recently played or seeked regions, decoded.** Rejected. 8 s of decoded audio is
  2.8 MB at 44.1 kHz and 12 MB at 192 kHz, a seek back already reuses the open file, and the
  measured seek after this change is a few milliseconds plus the decoder's seek. The SMB client
  already keeps the compressed blocks of open files.
- **A larger or smaller ring.** Rejected: 0029 measured the refill length's effect on CPU, and
  a seek doesn't wait for the ring to empty, so the size costs memory, not seek time.

## Consequences

- On the fixture FLAC, which afconvert writes without a seek table, `ExtAudioFileSeek` reads
  forward to the target: a seek 20 s on cost 30 ms locally and 140 ms on the simulated NAS, and
  80 s on 200 ms and 900 ms. FLAC from the reference encoder carries a seek table by default;
  nothing here measured whether AudioToolbox uses it. The scrub bench seeks 5 s on from a spot
  already read, so it measures the refill's wait, not this.
- A refill split by commands takes the scheduler's fast core in shorter runs, which 0029 found
  costs CPU; only a burst of commands splits it, and none come while a track simply plays.
- The old Mac's figure for the new bench is an estimate until its checkpoint.
