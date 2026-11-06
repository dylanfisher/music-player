# 0110. Pause, play and seek fade over 5 ms; DoP doesn't

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0011](0011-playback-engine-and-hal-output.md), [0064](0064-dsd-over-dop.md)
  ("Silence at the end" and "Unity")

## Context

Phase 49. The owner hears a pop on the ADI-2 when they play and pause quickly, and when they
seek or click in the progress bar. A pause stopped the device straight away and a play started
it at full level, so the DAC went from a sample mid-waveform to silence and back in one step; a
seek joined two places in the music the same way. Other players fade for a few milliseconds.
The fade must not cost the response, and every sample between fades must still reach the DAC
unchanged, which is what the signal path panel calls bit-perfect.

## Decision

**One length.** A fade is 5 ms, `fadeSeconds` in `HALRender.c`, as a frame count at the
device's rate: `HALRenderFadeFrames` (221 frames at 44.1 kHz, 960 at 192 kHz). Long enough not
to click, short enough to sound immediate.

**In the IO proc, as a frame counter.** The render state keeps where the fade is, from 0
(silence) to the fade's length (full gain). Inside a fade each frame is scaled by the counter
over the length, a straight line, on top of the digital volume and through the same per-format
sample code. At full gain the IO proc doesn't touch a sample, so playback between fades is the
file's bits, in integer and float device formats alike; nothing reachable from the IO proc
allocates, locks or logs, and the producer reaches the counter only through atomics.

**Pause.** `DeviceOutput` sets the render silenced and leaves the device running. The IO proc
fades out over the next frames and then writes silence without taking anything from the ring
buffer, so the position stays where the fade ended and play carries on from there. Once the IO
proc says it is silent for that request, the control thread waits out the device's latency, so
the fade has played rather than been cut by the stop, and stops the device on its next 10 ms
tick. A play before then turns the fade back from wherever it is. The stop comes a few tens of
milliseconds after the pause; what's heard starts fading as soon as the next buffer plays.

**Play.** A start whose audio doesn't begin at a track's first frame fades in from silence: a
resume, a play after a seek while paused, a load mid-track such as the resume after a quit or
a return of a lost device. A track from its first frame starts at full gain, from silence.

**Seek.** A discard that drops what's playing (a seek, a click in the bar, a track loaded over
the one playing on the same device) moves as many frames of the old audio as the counter
stands at into a buffer allocated with the render state, skips the rest at once as before, and
plays the held frames fading out, then the new audio fading in. A seek during a fade carries on
from where the gain is: one during a fade-out goes on fading the held frames, one during a
fade-in holds fewer frames from a lower gain. The skip still happens at the start of the cycle
that takes the discard, so a newer discard can't replace it while the held frames play.

**What doesn't fade.** A next track replaced while queued (a discard ahead of what the IO proc
has played), gapless track changes and format switches between tracks: these join the music as
it was recorded. A stop, a device switch and a double-click on a track of another rate still
cut; the owner asked about play, pause and seek, and those reconfigure the device anyway.

**DoP doesn't fade.** A DoP word is 16 bits of DSD bitstream under an alternating marker, not
an amplitude; scaling it breaks the markers and the DAC plays noise (0064). A real DSD fade
would mean modulating new DSD in the IO proc. DoP doesn't go through DoP silence on a pause
either: it stops at once and starts on the next pair of frames, as before, which keeps every
marker in order across a pause, a play and a seek (0064 "Continuous markers"). A device layout
the IO proc can't scale gets the opaque kind now instead of an Int32 stand-in, so it doesn't
fade either and plays as before.

**A UPnP renderer** decodes and plays the file itself, and pauses and seeks with its own
transport, so the app has no samples to fade. Whether the Denon or a Sonos clicks is theirs.

## Alternatives considered

- **Fading in Swift on the decode thread.** The ring buffer holds seconds ahead of the DAC, so a
  pause would wait for those seconds or rewrite them under the IO proc.
- **Moving the discard point a fade's length ahead instead of holding frames.** A next track
  named in those few milliseconds posts a newer discard, which would replace the seek's skip,
  and the old position would play on.
- **Blocking the control thread until the fade has played.** A play or a seek straight after
  the pause would wait behind it; the 10 ms tick already runs while the device does.
- **DoP silence on a DoP pause.** It would hold the DAC in DSD mode for the stop, but the music
  still cuts to it in one step, and a stop then follows anyway. Left for the owner's
  checkpoint to show it's needed.
- **A cosine or longer fade.** 5 ms of a straight line is what the owner asked for; anything
  longer starts to sound late.

## Consequences

The first 5 ms after a resume or a seek, and the last 5 ms before a pause or a seek, are not the
file's samples; everything else is. Tests that compare output after a resume or a seek skip the
fade-in. A pause now keeps the device running a few tens of milliseconds longer. If
DoP clicks on the ADI-2, the fix is DoP silence written by the IO proc on a pair boundary, which
this leaves room for: the IO proc already knows when it is silenced.
