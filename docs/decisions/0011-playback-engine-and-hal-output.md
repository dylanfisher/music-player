# 0011. A track-level output protocol, and a HAL output that decodes ahead into one ring buffer

- **Date:** 2026-10-30
- **Status:** accepted
- **Amended by:** [0023](0023-failure-table.md): the failure table, and the failures phase 14a
  changed how this reports. [0046](0046-failed-tracks-stop-playback.md): which failures stop
  playback.

## Context

Phase 4 turns the one-file `--play` into an engine with a queue, gapless playback, device loss
handling and a state stream. Phase 9 adds a UPnP renderer, which is handed file URLs and decodes
them itself, with `SetNextAVTransportURI` for gapless. The local DAC needs bit-perfect output,
a rate switch per track, and a real-time path that never allocates, locks, logs or calls Swift.
Nothing may play aloud on the build Mac, so tests and benchmarks need an output that consumes
audio without a device.

## Decision

**The `Output` protocol (Playback) works a track at a time:** load an item at a position, set the
next item, play, pause, stop, seek, position, volume and close. Results come back as events
(`trackStarted`, `trackEnded`, `formatChanged`, `trackFailed`, `finished`, `underrun`,
`deviceLost`, `deviceReturned`, `failed`), each naming the item it concerns. The engine gives every
load a fresh item ID, so it can ignore events about an item it has replaced. Playback has no
CoreAudio in it; HALOutput depends on it, and phase 9's UPnP output will too. What only a local
device can know is optional: `TrackInfo.outputFormat` and `FormatChange.switchSeconds` are nil
for an output that can't tell.

**Phase 9 maps an item to the renderer** without changing the protocol. `OutputItem.url` stays the
local file URL. The UPnP output asks the HTTP server for the URL it serves that file at (only files
the library knows), and builds the DIDL-Lite metadata (title, artist, album, duration and the
`protocolInfo` for the file's MIME type) from the library's row for that path. `load` becomes
`SetAVTransportURI` and `Play`, `setNext` becomes `SetNextAVTransportURI`, and the renderer's
`TransportState` and `CurrentTrackURI` events become `trackStarted`, `trackEnded` and
`finished`.

**`PlaybackEngine` is an actor.** It holds the queue (play order, shuffle, repeat off/one/all)
and tells the output the next item whenever the current one starts or the order changes.
`updates()` gives each subscriber its own `AsyncStream` of the state plus the event that changed
it. A failed track is skipped; after three failed in a row, or every track in the queue, playback
stops ([0046](0046-failed-tracks-stop-playback.md)).

**`DeviceOutput` (HALOutput) runs everything but the IO proc on one control thread.** It decodes
into the ring buffer and records where each track starts as a count of bytes written. The IO proc
publishes a count of bytes consumed (`HALRenderConsumedBytes`). When that count passes a track's
start, the track has started, so the event fires when the boundary is played, not when it is
decoded. Position comes from the same count.

- **Gapless:** a next track with the same rate and channel count is decoded straight after the
  current one, so the IO proc never sees a boundary. Bit depth doesn't matter, because the
  converter pads 16 or 24 bits into the device's 32 exactly.
- **Format change:** a next track that differs waits until the ring buffer is empty and the
  device's latency (buffer, safety offset, device and stream latency) has passed. Then the device
  is stopped, reconfigured and restarted. The next track's first half second is decoded while
  the old one drains, into the device's layout at the new rate, so after the drain only the
  device's own steps remain (stop, rate, format, start) and copying that audio in. Settling waits
  on property listeners for the rate and format rather than polling. The switch is timed from the
  old track's last sample playing, after the device latency; the first ADI-2 measurement
  (about 840 ms) started before that wait, so the two aren't strictly comparable.
  `FormatChange.steps` says where the time went, with an "other" step for what no step timed.
- **Discard handshake:** `HALRenderDiscard(from, to)` tells the IO proc to skip the bytes from
  `from` up to `to`. The producer writes what follows straight after `to`, so neither side waits,
  and nothing resets the ring buffer under the reader. Only the IO proc moves the read index
  (`RingBufferSkip`). The two positions are published under a sequence lock, so the IO proc never
  pairs one discard's start with another's end; a discard caught mid-write waits a cycle.
  - A seek, skip or load of the same format uses `from` = 0: everything queued is dropped at the
    IO proc's next cycle. The silence until the new audio arrives isn't counted as an underrun.
  - A changed next track that is already queued uses `from` = its first byte. The IO proc plays
    the current track to its last byte and skips from there, mid-buffer if need be, and the
    replacement follows with no gap. Boundaries already played are announced first, so the track
    playing now is never the one dropped.
  - The producer writes whole frames only, so every count stays on a frame edge.
- **Ring buffer:** four seconds, refilled once half empty (eight since
  [ADR 0029](0029-longer-decode-bursts-and-a-sleeping-control-thread.md)). That covers a NAS stall and the open of
  the next file, which happens on the same thread. The sizing is justified next to the constant in
  `DeviceOutput.swift`.

**The device is found by UID through `HALDeviceProvider`,** which listens to
`kAudioHardwarePropertyDevices` and to `kAudioDevicePropertyDeviceIsAlive` on the device's current
object ID. With no UID set, the system default is resolved once, at the start. If the device goes
away, the output drops everything and reports where to resume, and the engine pauses. It never
moves to another device. When the device comes back, the default outputs are put back and the
engine offers to resume. Hog mode follows `output.hogMode`; without it only mixable formats are
chosen, since a non-mixable one would lock other apps out.

**Restoring the device:** the first open in a run snapshots the device's rate and format and
the system's default outputs, by UID, and every later session restores that snapshot. Closing runs
every restore step (stop, format, rate, hog mode, default outputs) even when one fails, then
reports the first failure. `device-restore.json` in the data folder holds one snapshot per device
UID: a session adds its device's entry once it holds the device, never replaces one already there
(that one holds the older state, and the session restores to it), and removes it after a clean
restore. `HALDeviceProvider.recoverAfterCrash` restores from a record
left by a crash, a kill or an unplugged device the next time the CLI plays. coreaudiod releases
hog mode itself when a process dies.

**Digital volume** is an atomic gain in `HALRender`, ramped across one buffer and applied only
when it isn't exactly 1, so with `output.digitalVolume` off the samples are copied untouched.

**`NullDevice` (Fixtures)** implements the device seam by calling `HALRenderIOProc` on its own
thread at real-time pace or a multiple of it, and can keep what it pulls. Tests check the ramp
albums (one continuous ramp split into two tracks) for sample-exact continuity, the rate-change
sequence, seek, pause and device loss. The benchmarks measure CPU, gap, switch time and
underruns through it.

## Alternatives considered

- **A PCM-level output protocol** (the engine pushes samples) — rejected: a UPnP renderer fetches
  and decodes the file itself, so it can't be driven sample by sample.
- **Stopping the IO proc to seek, or a flush flag that resets the ring buffer** — rejected: a
  reset from the producer races the reader. Stopping and restarting the device costs tens of
  milliseconds per seek and clicks on some DACs.
- **Re-decoding the current track to replace a queued next one** (seek to the frame playing now,
  dropping everything queued) — rejected: the ring buffer is usually full then, so the new audio
  can't be written before the discard lands, and the IO proc plays silence. The range discard
  keeps the current track's queued audio.
- **A second ring buffer per track** — rejected: the IO proc would have to switch buffers at an
  exact byte, which one buffer and a byte count already give for free.
- **Following macOS to the new default device when the DAC is unplugged** — rejected: it would play
  out of the speakers at the DAC's volume, which is the failure the plan forbids.
- **A trap handler that restores the device on a crash** — rejected: CoreAudio calls aren't
  async-signal-safe. The restore record handles every way a run can end, including `kill -9`.

## Consequences

- Event timing is accurate to the 10 ms control tick plus the device's buffer, not to the sample.
- Opening a file blocks the control thread. A very slow NAS open delays commands such as pause,
  but not audio, which has seconds queued.
- A mono file on a stereo-only DAC fails with a clear error and is skipped. Upmixing would change
  the samples.
- At real-time pace, 24/192 FLAC measured 2.73% of a core on Apple Silicon, against a 2% target.
  The same work run flat out costs 0.9%: the CPU runs short bursts at a low clock. About a quarter
  of decode time is AudioToolbox scanning FLAC packets byte by byte (`FLACAudioFile::
  ScanForPackets`), which only a decoder of our own would avoid. The owner raised the Apple Silicon
  budget to < 3%. A FLAC decoder of our own is revisited only if the 2015 MacBook Pro misses its
  5% at the phase 5 checkpoint.
- The rate-switch time the benchmark measures excludes the real device's own settling, which the
  hardware checkpoint measures.
