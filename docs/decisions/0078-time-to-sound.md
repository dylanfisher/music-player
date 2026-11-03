# 0078. A new queue played at once keeps the device open, and open files are reused

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0070](0070-start-before-the-queue-is-read.md)

## Context

Phase 32a measures from a play action to the first sound. Nothing measured that before: the
double-click bench (0070) stops at the output's `trackStarted`, and the null device closed,
opened and switched rates at no cost, so a double-click that tore the device down looked free.

A real device's close puts back the rate and format it had before the app (`HALDevice.close`,
waiting up to 3 s for them to settle) and releases hog mode; the next open finds the device,
writes the restore record, takes hog mode and sets the rate again. On a DAC that sat at 48 kHz,
a 44.1 kHz double-click while playing paid two rate changes. Every file the output opens on the
NAS costs round trips before its first frame.

## Decision

**The bench.** `NullDevice` takes `HALDelays`: opening, a rate change settling and releasing
hog mode. With them set, closing a session puts back the rate of the first open, as
`HALDevice` does. The values are estimates, 10 ms to open, 100 ms for a rate change and 5 ms
for hog mode, until the ADI-2 checkpoint; nothing here has timed a real device's steps. The
device starts at 48 kHz. It times the first IO cycle after an action that pulls anything but
silence, and each case runs while a fixture track plays 10 s of silence before a ramp.

`DeviceOutput` takes an optional `FileLatency`, for benchmarks only: the decoder then opens the
file through AudioFile callbacks, and pays an open and a read per 1 MB block first touched, as
an SMB client that reads ahead and keeps what it read. Charging each of AudioToolbox's own
small reads made a FLAC seek take minutes, which no SMB mount does. The cases use the slow
simulated NAS: 23 ms to open and 10 ms a block.

**A new queue played at once doesn't stop the output.** `play(starting:completing:)`, the
double-click, forgets what the output has loaded and lets the output's `load` replace it. The
output already handles that load as it does Next's: the open stream restarts when the track
fits it, and the open device is reconfigured when it doesn't. Stop, and `setQueue` on its own,
still close the device, so the device isn't held in hog mode while nothing plays.
`play(_ request: PlayRequest)` in `AppDelegate` (the timeline and scripting) still goes through
`setQueue` and `play`; it is off the double-click's path.

**A queue's paths are read in `IN` lists.** `paths(ids:)` ran one statement per ID; it now uses
`inChunks`, as `rows(ids:)` does. The clicked track already plays before the queue is read
(0070), so this shortens only the time the queue panel shows the one track: 166 ms to about
70 ms for the whole library.

**Open files are reused.** A load takes a track the output already has open on the same file,
rewound, before opening it again: Next's track, opened when the engine named it, or the track
playing. Each segment in the ring buffer keeps its track open, so a seek back into a track whose
decoding has moved on rewinds that decoder instead of opening the file. At most the tracks whose
audio is in the 8 s ring buffer stay open.

## Consequences

Median of five on the build Mac, slow simulated NAS and local files, before (the bench commit)
and after, the same day:

| Action | Before | After |
|---|---|---|
| Double-click, same rate | 294 ms, 244 ms | 48 ms, 10 ms |
| Double-click, another rate | 297 ms, 249 ms | 169 ms, 107 ms |
| Next | 57 ms, 11 ms | 10 ms, 5 ms |
| Seek while the track is decoded | 6 ms, 11 ms | 7 ms, 5 ms |
| Seek after decoding moved on | 57 ms, 5 ms | 10 ms, 11 ms |

- Up to one IO cycle (11.6 ms at 44.1 kHz) of each figure is where the action lands in the
  device's cycle.
- What's left of a double-click on another rate is one rate change: the device's own time.
- A double-click on the NAS still opens the new file. That is the first block's round trips.
- The before and after rest on estimated HAL times; the ADI-2 checkpoint says how it feels.
