# 0035. The signal path panel follows the HAL's listeners and judges a snapshot

- **Date:** 2026-11-01
- **Status:** accepted

## Context

Phase 20 shows what happens to the samples between the file and the DAC, with a verdict:
"Bit-perfect", or each thing that changes them. Another app can change the device's rate, take
hog mode or move a volume control at any time, and the panel has to show it at once without
polling. Nothing reachable from the IO proc may change (ADR 0011), and phase 9's renderer will
need to show its own path in the same panel.

## Decision

- **A snapshot and a pure verdict.** `SignalPath` (Playback, plain values, no CoreAudio) holds
  the audible track's file and decoder formats and a `SignalSink`. The sink is an enum whose one
  case is the device: its name, whether it's connected and readable, nominal rate, first output
  stream's physical format, mixability, hog owner, volume controls, and the IO proc's gain. The
  renderer becomes a second case. `signalVerdict(_:)` judges it; NowPlaying turns the result
  into text.
- **What counts as a change:** the decoder or the device at another rate or channel count than
  the samples written to it; a decoder or device format that can't hold every value of the
  file's samples (integers widen into wider integers, and into a 32-bit float up to 24 bits);
  a mixable physical format; hog mode free or held by another process; any volume control, or
  the digital volume, not exactly 1; the device missing or unreadable. A lossy file has no depth
  of its own, so its precision is the decoder's output.
- **Volume at unity** reads, on the device's output scope where present, the virtual main
  volume (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, the system slider, which the
  HAL derives from the device's controls), the main control (element 0) and one per channel of
  the stream, plus the gain `DeviceOutput` sets with `HALRenderSetGain`, reported as 1 when
  digital volume is off. Unity is exactly 1.0. The approximation: streams have no volume
  property in the HAL, so a device that scales samples by a control it doesn't publish, or by
  DSP inside the DAC, reads as unity; mute isn't read.
- **Listeners, not polling.** The provider adds listeners on its existing device-watch queue for
  the device's nominal rate, hog mode, stream list and volume controls, and the stream's
  physical format. Each fire reads the state again and reports it through `watch`'s new `state`
  closure, in order. `PropertyListeners` keeps one block's listeners equal to the wanted set: a
  device plugged back in has new object IDs, so diffing removes exactly what was added to the
  old ones, and `stopWatching` (on close and quit) sets it empty.
- **The control thread composes.** `DeviceOutput` posts each state to its control thread like any
  command and, after each pass, publishes a `SignalPath` on `signalPaths` when it differs from
  the last one: one comparison per pass, no new lock, and the IO proc and `HALRender` untouched.
  The app reads the stream on the main actor, which is the hop to main.
- **The panel** is a strip under the now-playing bar, so the browser's columns keep their width:
  the verdict, then file, decoder, device, hog mode and volume. ⌥⌘S and View → Show Signal Path
  toggle it; `window.signalPathVisible` in the state file, off by default, keeps it.

## Alternatives considered

- **Polling the device on a timer** — rejected by the plan, and it would show a change up to a
  tick late.
- **Composing the path on the main thread from the engine's updates and the provider** —
  rejected: the gain and the decoder format the output actually uses live on the control thread,
  and the engine would have to carry fields only this panel reads.
- **A side panel beside the queue** — rejected: it takes width the track table needs at
  1440 by 900, where a strip of five rows costs about 110 points of height.

## Consequences

When hog mode is off in the settings, the format is mixable and hog mode isn't held, so the
verdict always names both. A device that publishes a volume control it doesn't apply to the
samples reads as changed until that control is at full. Phase 9 adds a `SignalSink` case and a
branch in `signalVerdict` and the panel text, without changing the device case.
