# 0074. Album art loads a few at once, off the cooperative pool

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The Album Art column read one cover at a time, each in a detached task. On the NAS a read
costs about 40 to 60 ms, so a screen of covers arrived one after another: the scroll bench's
page down, sorted by title so most rows ask for their own cover, waited 645 ms for the last one
at the slow simulated NAS's latency (ADR 0073). Each read also blocked a thread of Swift's
cooperative pool, which has one thread per core, 4 on the 2015 MacBook Pro, and every other
task in the app, the library queries included, waits for a free one. The now-playing bar, the
system's Now Playing and the art viewer read the same way.

## Decision

`ArtworkLoader.load` reads and decodes on a concurrent dispatch queue of its own, and returns
to the caller's actor. All four callers use it. The column keeps up to `RowArt.loadsAtOnce`
reads going, one short of `ProcessInfo.activeProcessorCount` and at least 2: 3 on the 2015
MacBook Pro, which leaves a thread for the main thread and playback, and 9 on the build Mac. A
cover being read isn't asked for again. The page down's last cover now comes after 136 ms.

## Alternatives considered

- **A fixed count, 3 or 4** — rejected: the orchestrator's rule is that limits scale with the
  Mac, with the old Mac as the floor.
- **Every core** — rejected: on the old Mac, decoding covers on all 4 threads competes with the
  audio decode while a track plays.
- **Keeping the detached tasks and only adding more of them** — rejected: more reads in flight
  would hold more of the pool's few threads.

## Consequences

- A slow read holds a dispatch thread instead; GCD adds threads when they block, up to its own
  limit, which `loadsAtOnce` stays far below.
- On a fast NAS or a local disk several covers decode at once, so a fast scroll uses more CPU
  for a moment than before.
