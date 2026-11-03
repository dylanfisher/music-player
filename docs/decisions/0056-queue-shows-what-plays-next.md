# 0056. The queue shows what plays next

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0013](0013-library-window-data-flow.md)

## Context

Playing a track queues the whole visible list (0013), so the engine's queue can hold an artist's
3,229 tracks. The queue panel listed all of them from the first, played or not, so a track queued
with Play Next sat thousands of rows down, after the playing track. Add to Playback Queue was
worse: the engine put it after the last track of the list, so it played only after all of them.

## Decision

- **The engine's queue marks the tracks the user queued.** `PlayQueue` keeps, per entry, whether
  it came from Play Next or Add to Playback Queue rather than from the list playback started in.
  The mark moves with the entry through moves, removals and shuffled edits, and a new queue clears
  it.
- **Play Next goes straight after the current track**, as before, so the latest Play Next plays
  first. **Add to Playback Queue goes after the current track and the marked tracks that follow
  it**, so adds play in the order they came, after every Play Next, and before the rest of the
  list.
- **The panel lists the queue from the current track on.** Row 0 is the current track, marked;
  played tracks aren't listed. The engine keeps them, so Previous and repeat all still reach
  them. With no current track the panel lists the whole queue. Its rows map to the engine's
  positions by the current track's position, for play, remove and drag.

## Alternatives considered

- **A separate up-next list in the engine, as Swinsian keeps** — rejected: next, previous, repeat,
  shuffle and every edit would have to walk two lists, and the play order would no longer be one
  array the output's next track is read from.
- **Counting the queued tracks after the current one** — rejected: every move, removal and track
  change would have to update the count, and the mark per entry needs none of that.
- **Dropping played tracks from the engine's queue** — rejected: Previous and repeat all would
  have nothing to go back to.

## Consequences

Turning shuffle on mixes queued tracks into the shuffled rest, and turning it off lists tracks
queued while shuffled last, as before. A queued track keeps its mark after it plays, so going back
before it and adding a track puts the add after it. A drag in the panel drops below the current
track, and the current track's row doesn't drag: a track moved before the current one counts as
played and would leave the list.
