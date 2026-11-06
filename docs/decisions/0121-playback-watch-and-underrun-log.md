# 0121. The log names a stuck playback call and says why each underrun happened

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0081](0081-hung-share-off-the-main-thread.md) (a stuck call on the output's
  control thread is logged), [0083](0083-buffering-review.md) (underruns are reported during a
  refill, not after it)

## Context

The owner reported on 2026-11-06 that hi-res tracks drop out now and then while the NAS's disk
is busy, and that the app hung once. The system log for the hang showed a 24/192 FLAC opened and
its decoder set up on the output's control thread at 14:40:40, then nothing from that thread:
the device never started. Quit at 14:41:06 waited the 6 s ADR 0081 allows and logged "the
outputs didn't close". Nothing said which call was stuck, a NAS read or a HAL call. The app
logged no underruns at all: only the `play` command printed them.

Part of the same gap: `service` checked for underruns only after `fill` returned, and a refill
runs until the ring is full. On a share slower than the audio the ring never fills, so the
refill ran to the end of the track and its silence was reported then, or never.

## Decision

**A watch on the control thread's blocking calls.** `StepWatch` (HALOutput) wraps every call
on the control thread that can block: opening a track's file, each read, seek and format set
of its decoder (`WatchedDecoder`), and opening, configuring, starting, stopping and closing the
device. A call still running after 2 s is logged as an error, "playback is stuck: reading a
track's file hasn't returned after 2.0 s", and its return as "playback carried on: … returned
after 7.3 s". File paths are logged hashed, as ADR 0118 keeps them; device names are public.
A call that never returns leaves the stuck line as the thread's last word before the quit
timeout. 2 s is longer than a NAS read or a device switch takes when nothing is wrong (a
device switch's waits are bounded at 3 s each) and short of the ring's margin for a stall,
about 5.5 s.

The watch schedules one check at a time on a global queue, and only while a call runs: the
first call arms it, and a check that finds nothing running doesn't rearm. During playback that
is about one wakeup per refill. Each call takes an `NSLock` twice; the IO proc never takes it.

**Underruns are logged with the refill under way.** `fill` checks for underruns after each
chunk it writes, and `service` once a pass as before. Each underrun is logged as an error:
"underrun: 120 ms of silence during a refill that has written 1.2 s of audio in 6.3 s, from
5.5 s queued", or "while no refill was running" when the ring drained while the thread did
something else. A read that stalled shows as a long refill that wrote little; a share slower
than the audio throughout shows as a refill that wrote less audio than the time it took. The
engine's `.underrun` event is unchanged and now arrives as the silence happens.

## Alternatives considered

- **Moving file reads off the control thread now**, so a stuck read can't hold playback,
  commands or quit. Not yet: it's a large change to `DeviceOutput`, and the owner chose to
  find out first whether the hang is a NAS read or a device call. This change says which.
- **Sampling the control thread's stack when it's stuck.** Rejected: suspending a thread to
  read its stack needs task ports the app doesn't hold, and the step names the call already.
- **A repeating timer for the watch.** Rejected: it wakes the app while nothing plays, which
  ADR 0029 took out of the control thread.
- **Pausing library analysis while a track plays from the share.** Declined by the owner:
  analysis should finish as fast as it can.

## Consequences

- A device switch that takes over 2 s is logged as stuck and then as carried on, though nothing
  is wrong but a slow device.
- Lines go to the unified log at error level, so they persist and appear in Copy Details.
