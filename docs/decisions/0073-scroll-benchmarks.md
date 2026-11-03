# 0073. The scroll benchmarks time the app's main thread a frame at a time

- **Date:** 2026-11-03
- **Status:** accepted

## Context

Phase 32b asks why scrolling a 43k-track library with album art might not be smooth on the 2015
MacBook Pro. The scroll-bar-drag benchmark (phase 28) jumps a screenful a step, never lets the
run loop turn between steps, and decodes art through a loader of its own, so no art the table
asks for reaches the screen while it measures. It can't show trackpad scrolling, art arriving,
art over the NAS, or a scan's refreshes. Each suspect needs a number before it's fixed.

## Decision

The app takes `--measure-scroll trackpad|scan` and `--art-delay-ms <ms>`, beside
`--measure-window` (ADR 0014). Once the table first draws rows it scrolls to the middle of the
list (the top holds the untagged files, which have no art) and a 60 Hz timer moves the rows in
trackpad flicks: 80 points a frame, shrinking by 5% a frame until under a point, then the next
flick, for 600 frames. A run-loop observer adds up the time the main thread waits, so each
frame's busy time is everything else it did: the scroll, the drawing and Core Animation commit,
art arriving, a refresh. Every art read goes through a closure the measurement wraps, which
counts the reads and sleeps for the delay first. With `scan`, the browser hears a scan's
progress as often as the watcher sends it, so it refreshes every 2 s through its real path, and
the measurement notes the frames a refresh landed in. After the last frame it pages down and
times until every row on screen shows its art. It prints one `ScrollReport` line.

Bench launches the app for four cases: the default layout with the Album Art column; compact
rows under a 256-point art column, so fixture albums of 15 to 24 tracks run past their covers;
sorted by title, so nearly every row is an album's run of its own, with each art read delayed
by the slow simulated NAS's opening, read and closing plus its median disk wait (43 ms); and the
scan. It reports the p95 frame and the worst frame, the median of the frames a refresh landed in,
and the time to the last cover after the page down.

The queue panel's track change is timed in Bench's own process, through `QueuePanel.show`,
since what it costs is the panel's rows and nothing the app adds.

## Alternatives considered

- **Synthesized scroll-wheel events** — rejected: posting them needs accessibility permission,
  and a gesture's phases can't be reproduced reliably, so runs wouldn't compare.
- **The simulated NAS itself** — rejected: it lives in Tools, which the app can't import. A
  fixed delay per read is what an art read costs; the delay is computed from the same profile.
- **Timing only the scroll call** — rejected: a refresh or an image arriving runs between
  frames, which is the cost the suspects are about.

## Consequences

- Most of a frame is AppKit drawing the rows that scroll in and Core Animation's commit, which
  waits on the window server. That part varies a lot from run to run on the build Mac, so a
  close comparison needs several runs on a quiet machine.
- Fixture covers are small (at most 300 px) and only about a third of fixture albums have one,
  so decoding and drawing cost less than in the real library. Phase 32e.3 adds large covers.
- The app's launch work still runs during the first frames, as in ADR 0014.
