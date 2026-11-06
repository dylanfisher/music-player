# 0112. A renderer's track ends by the app's clock

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0041](0041-upnp-output.md) ("Gapless, and the app leads" and "What the polls
  confirm")

## Context

Playing to the Denon, a track ended and the next never started (phase 48e). Under 0041 the
session ended a track when the renderer stopped within 3 s of its end by the last position
polled, and it moved its own end later whenever two polls found the renderer more than 1.5 s
behind its clock. The Denon's positions lag what it plays: its last report before it stops is
more than 3 s short of the end. So the stop counted as one on its remote and the engine
stopped, and while it played, every poll moved the app's end later by the lag. The Denon also
takes `SetNextAVTransportURI` and doesn't play the track it was given.

## Decision

**The app's clock decides when the next track goes out.** `RendererClock` holds the loaded
track's clock. It starts at the first poll that finds the renderer playing, at the position
polled then; it pauses and resumes with the transport, from its own reading rather than the
polled position; a load or a seek sets it. Its deadline is the track's length in the file
past the start, plus `RendererClock.leadMarginSeconds` (2 s). The session no longer waits for
a report of the end.

**A poll moves the end later only for a stall.** The clock keeps the least the renderer has
been behind it since its position first moved, its usual lag. Two polls running that find it
more than `behindToleranceSeconds` (1.5 s) further behind than that, while the clock is short
of the track's length, move the end later by that much, never earlier, and by at most
`RendererClock.stallCapSeconds` (10 s) from a start or a seek. After a pause the lag is
measured again and new stalls add to earlier ones. A renderer that lags by the same amount
throughout moves nothing, and one stuck at its end, behind the clock once the clock is past
the length, moves nothing.

A stall before the position first moves can't be told from a lag, as both report the start
for a while, so it moves nothing; the track's last seconds may then be cut by up to the stall
less the margin. The polls can't separate them, and a lag is what the Denon shows.

**A stop counts as the end** when the clock, unmoved by stalls, or the last position polled
is within `endSlackSeconds` (3 s) of the track's length. Any earlier stop is reported as one on
the renderer, as before.

**A renderer that ignores the next URI.** After it took a next track with
`SetNextAVTransportURI`, a renderer that stops at the end on two polls running
(`stoppedAtEndPolls`; one may come between tracks), or is still on the track at the clock's
deadline, is marked `RendererGapless.afterStop` with the reason, which the signal path
carries. The next track goes with `SetAVTransportURI` and Play at once. From then on, while
the session lasts, `setNext` sends no next URI, so every later track goes the same way when
the last stops, or at the clock's deadline. A renderer found again at a new address reads its
description again, as before.

**The log.** Each poll in a track's last 15 s by the clock and the 15 s after a track change
logs, at notice level, the transport state, the renderer's position, duration and `TrackURI`,
and the clock, with how far stalls moved the end; an accepted next URI, the lead, the gap and
the mark are logged too. These are public in the unified log, since the owner reads them with
`log show`. The URLs carry the tokens, which serve only to the renderer's address and end
with the server (0041).

## Alternatives considered

- **Moving the end by how far behind the renderer is, as 0041 did** — rejected: a lag looks
  the same as a stall, and holds the next track back for as long as it lasts.
- **No moving at all** — rejected: a renderer re-buffering mid-track would have its last
  seconds cut by the length of the stall.
- **Waiting out the clock after a stop with the next URI given, as 0041 did** — rejected: with
  the end moved by the lag the wait never ended, and a renderer that stops at the end with a
  next track it took has shown it won't play it.

## Consequences

The next track starts within about two polls of a stop at the end, or 2 s past the clock's
end for a renderer that plays on. A renderer that plays next URIs keeps gapless. To be checked
at the Denon (48e's checkpoint): three track ends in a row, each next starting within about
2 s, and the log lines show what it reports.
