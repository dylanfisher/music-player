# 0070. Start the clicked track before the queue behind it is read

- **Date:** 2026-11-03
- **Status:** accepted

## Context

A double-click in the track table queues every row of the visible list, 43k tracks for the whole
library. Building that queue looked up each row's path with its own query, put the results in a
dictionary and made a URL per row, all before the engine was told to play. On the build Mac that
took 223 ms from the click to the first frame in the output, 45 ms of it on the main thread. The
2015 MacBook Pro is several times slower. Everything after the engine's `load`, including opening
the file, which on the NAS can take far longer, already runs on the output's own thread.

## Decision

- `BrowserModel.playStart` resolves only the clicked track's path (one query) and returns a
  `PlayStart`: that URL, and a closure that reads the whole queue. It runs off the main actor,
  on the reader and the cooperative pool.
- `PlaybackEngine.play(starting:completing:)` queues just that track and plays it, then replaces
  the queue with the full one when the closure returns, keeping the track that is playing as the
  current one. The queue is still a list of URLs in the engine; it is built once, off the main
  thread, instead of being shared as ids, because every consumer (queue panel, Now Playing, play
  counting, remote control) already reads URLs from `PlaybackState`, and a lazy queue would
  change all of them for a copy that costs about 1 ms.
- Seen from outside, the queue is one track for roughly the time a lookup of 43k rows takes, then
  the whole list, announced by a second `queueChanged`.
- A new queue before the full one arrives wins, and the late queue is dropped. Play Next, Add to
  Queue, Next and Previous are held and applied, in order, to the whole queue once it is there
  (Next or Previous stands in for the track's end). A move or removal counts positions in the
  one-track queue the user saw, so it is applied at once and the late queue is dropped.
- If the track ends or fails before the queue arrives, the end is held until it does, so a failed
  first track still moves on to the next one. If the queue can't be read, or no longer has the
  track where it started (a rescan removed it), the engine reports the error, carries on with
  the one track and replays what it held, so a held end still ends playback.
- Play requests built elsewhere (the timeline, scripting) still hand over a whole queue; they are
  small or already off the click's path.

## Consequences

- Double-click to first frame on the build Mac went from 223 ms to 7.6 ms, and main-thread time
  from 45 ms to 0.95 ms (`playback: double-click to first frame…` in `scripts/bench`).
- For a short time after the click, the queue panel shows a one-track queue.
