# 0011. A track-level output protocol, and a HAL output that decodes ahead into one ring buffer

- **Date:** 2026-10-31
- **Status:** accepted

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
CoreAudio in it; HALOutput depends on it, and phase 9's UPnP output will too.

**`PlaybackEngine` is an actor.** It holds the queue (play order, shuffle, repeat off/one/all)
and tells the output the next item whenever the current one starts or the order changes.
`updates()` gives each subscriber its own `AsyncStream` of the state plus the event that changed
it. A failed track is skipped; once every track in the queue has failed in a row, the queue ends.

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
  is stopped, reconfigured and restarted with half a second queued.
- **Seek handshake:** `HALRenderDiscardBefore(n, from)` tells the IO proc to skip every byte
  before `n`, at the start of its next cycle. The producer writes the new audio after `n` straight
  away, so neither side waits and nothing resets the ring buffer under the reader. Only the IO
  proc moves the read index (`RingBufferSkip`). Silence until the next full buffer, or while the
  producer says it is draining, isn't counted as an underrun. Skips and a changed next track use
  the same path. A changed next track seeks the current one to the frame playing now and passes
  the consumed count it read as `from`; the IO proc then also skips what it played since that
  read, so the current track carries on with no gap and no repeat. The two values are published
  under a sequence lock, so the IO proc never pairs one discard's target with another's `from`,
  and a discard caught mid-write waits for the next cycle. The producer writes whole frames only,
  so every count stays on a frame edge.
- **Ring buffer:** four seconds, refilled once half empty. That covers a NAS stall and the open of
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
the system's default outputs, by UID, and every later session restores that snapshot. The
snapshot is written to `device-restore.json` beside the settings while a session holds the device,
and deleted after a clean restore. `HALDeviceProvider.recoverAfterCrash` restores from a record
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
- **Range discards** (drop the bytes between two positions, to replace an already queued next
  track without touching the current one) — rejected: the IO proc would have to split a read at an
  arbitrary byte. Re-decoding the current track from the frame playing now costs a little decoding
  and needs only the continuation skip.
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
- At real-time pace, 24/192 FLAC costs about 2.7% of a core on Apple Silicon. The same work run
  flat out costs 0.9%: the CPU runs short bursts at a low clock. About a quarter of decode time is
  AudioToolbox scanning FLAC packets byte by byte, which only a decoder of our own would avoid.
- The rate-switch time the benchmark measures excludes the real device's own settling, which the
  hardware checkpoint measures.
