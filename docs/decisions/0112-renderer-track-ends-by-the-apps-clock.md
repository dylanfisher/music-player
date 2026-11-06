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
been behind it, its usual lag, measured from the first poll the clock runs through after a
start or a seek and kept across a pause, so a renderer that holds a moment after each resume
adds the holds up behind it. Two polls running that find it more than `behindToleranceSeconds` (1.5 s)
further behind than that, while the clock less the stalls so far is short of the track's
length, move the end later to the stall so far plus that excess: never earlier, and by at most
`RendererClock.stallCapSeconds` (10 s) from a start or a seek. A lag measured at the first poll
counts for 1.5 s at most, a poll's noise, so a renderer that reports playing while it holds at
the place it started, buffering after a start or a seek, has the hold taken as a stall rather than as its lag: otherwise the clock would run that far ahead all track and the
end would come early. A renderer stuck at its end, behind the clock once the clock is past the
length, moves nothing.

A renderer whose positions only lag, as the Denon's are thought to, looks the same as one that
held at the start, so its end moves later by the lag. That costs nothing when it stops at its
end, since a stop counts by the clock unmoved by stalls (below); one that plays on past its end
gets the next track that much later.

**A stop counts as the end** when the clock, unmoved by stalls, or the last position polled
is within `endSlackSeconds` (3 s) of the track's length. Any earlier stop is reported as one on
the renderer, as before.

**A renderer that ignores the next URI.** After it took a next track with
`SetNextAVTransportURI`, a renderer that stops at the end on two polls running
(`stoppedAtEndPolls`; one may come between tracks, and a TRANSITIONING poll starts the count
again), or that the clock's deadline finds still on the track within
`leadShortSeconds` (1 s) of its end or past it when it's asked for its position, is marked
`RendererGapless.afterStop`. One that the deadline finds on the next track has just moved on,
and the change counts as gapless. One still further short of the end is behind the clock: the
end moves to when it will get there, within the stall cap, and only once the cap leaves no
room is it marked and led. One that doesn't answer is led without being marked. The mark carries a short reason defined
once in `RendererSession`, which the signal path panel shows after "not gapless", as it does
the reasons for a renderer without the action or one that refused it; the errors behind those
go to the log. The next track the renderer holds is taken back with an empty
`SetNextAVTransportURI`, so it can't go on to it after the app has sent it; a renderer that
doesn't answer that is logged, not lost, since it's still playing. The next track goes with `SetAVTransportURI` and Play at once. From then on, while
the session lasts, `setNext` sends no next URI, so every later track goes the same way when
the last stops, or at the clock's deadline. A renderer found again at a new address reads its
description again, as before.

**The log.** Each poll in a track's last 15 s by the clock and the 15 s after a track change
logs, at notice level, the transport state, the renderer's position, duration and `TrackURI`,
and the clock, with how far stalls moved the end; an accepted next URI, the lead, the gap and
the mark are logged too. These are public in the unified log, since the owner reads them with
`log show`. The URLs carry the tokens, which serve only to the renderer's address and end
with the server (0041). A `TrackURI` that's neither the current nor the next track's is
another app's, and is logged only as "another track".

A position more than `jumpBackSeconds` (2 s) behind the last one polled starts the lag's
measurement again, keeping the stalls so far: a renderer may report where it was before a
seek back for a poll or two, which would otherwise set a lag far ahead of the clock.

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
