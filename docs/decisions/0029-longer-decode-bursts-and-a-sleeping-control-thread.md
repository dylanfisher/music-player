# 0029. Longer decode bursts, and a control thread that sleeps while stopped

- **Date:** 2026-11-01
- **Status:** accepted

## Context

Phase 14e needed playback CPU at 85% of its 3% budget or less; it measured 2.62–2.82%. A Time
Profiler trace of `scripts/bench` showed the work is AudioToolbox's: libFLAC decoding and
AudioFile's byte-by-byte scan for FLAC frame boundaries, about 0.76% of a core per second of
audio on a fast core, whatever the read sizes. At real-time pace the same work cost twice that,
because about half of each refill ran on an efficiency core or at a low clock. The ring buffer
was four seconds (5.5 s at 192 kHz after rounding), refilled once half empty, so each refill
decoded under three seconds of audio in about 20 ms.

Separately, the control thread woke 20 times a second while a track was loaded but stopped, as
when the app restores a paused track at launch, though nothing moves then.

## Decision

- **Eight seconds of ring buffer**, still refilled once half empty. Each refill runs twice as
  long, the scheduler moves it to a fast core for more of it, and playback CPU fell to 1.93–2.07%.
  The margin for a NAS stall grows with it.
- **The control thread sleeps until a command** when the output is stopped and no refill is due.
  Its 10 ms tick while running is unchanged, so events and positions are as timely as before.

## Alternatives considered

- **Refilling at a quarter full instead** — rejected: it cut CPU by 11% but halved the margin for
  a NAS stall.
- **Raising the decode thread's priority** — rejected: it already runs at user-interactive QoS,
  and forcing fast cores costs energy for a number that only measures time.
- **Parsing FLAC frames ourselves** so AudioFile doesn't scan them — rejected: a second container
  parser on the playback path for real files with messy tags, for about a third of decode time.
- **A longer tick while running** — rejected: it saved about 0.2% but makes every event and the
  published position later.

## Consequences

The ring buffer doubles in memory: 4 MB at 44.1 kHz, 16 MB at 192 kHz and 64 MB at 768 kHz,
after rounding, within the 250 MB resident budget. A burst still lands on whichever core the
scheduler picks, so the saving depends on it; the 2015 MacBook Pro has no efficiency cores and
gains nothing there.
