# 0104. A play from the queued list keeps the queue across library changes

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0097](0097-playing-row-text-and-keeping-the-queue.md) (when the kept list is
  forgotten)

## Context

ADR 0097 made a play from the track table keep the queue, as Next does, when the list (its
track IDs in play order) is the one the last play queued and the engine's queue is still that
list's. The owner found that with the queue panel open, Enter or a double-click on the track
after the playing one still rebuilt the panel.

The engine and the panel do what Next does once the browser model hands over the kept queue:
the engine moves and loads as Next does, and the panel drops the rows played and keeps the
rest. The model rarely handed it over. It forgot the kept list on every library refresh, and
most refreshes don't come from a scan:

- Each counted play and each counted skip refreshes the list, to show the new counts. A track
  counts a play partway through (`PlayCounter`), and Enter on the next track before then
  counts a skip of the one playing, so the list was forgotten partway through the first track,
  and right after any play in place.
- A rating or an opinion refreshes it the same way.
- A scan refreshes it every 2 seconds while it runs, including a network folder's poll that
  finds nothing changed.

A play from the same list also forgot any queue it was reading when a refresh came during the
read, which a counted skip makes likely, since one is counted as the play starts.

## Decision

- **An edit that moves no file keeps the list.** Ratings, opinions, counted plays and counted
  skips run the queries again without touching the kept list (`refreshEdited`).
- **A library change checks the list instead of forgetting it.** After the refresh, the model
  reads the kept list's files again, on the refresh connection, and keeps the list when every
  track's file is where it was, and forgets it otherwise. Until the check is done, a play from
  the list builds the queue, as before. A queue whose read overlapped a library change is kept
  and checked the same way.
- **The play state resumed at launch counts as a play.** Its queue is the list of the source the
  track was played from, in that source's sort (ADR 0095), and the model keeps it as it keeps a
  play's. When the table shows that source unfiltered in that order, the first play from it
  plays in the restored queue. The engine still compares its own queue with the kept one, so a
  restored queue that was edited or replaced isn't played in place.

Rejected: checking the engine's queue against the table's list at each play. It needs the
list's files before the clicked track can start, the lookup that ADR 0070 moved off the click.

## Consequences

- Every refresh while a list is kept reads that list's files once more, off the main thread.
  For the whole library, 43k tracks on the build Mac, the whole queue is read in under 60 ms
  (`scripts/bench`).
- A play from the list during that read builds the queue, as before 0097.
- The launch case plays in place only for the source's whole list: a list narrowed by the
  columns or a search at quit is restored as the whole source, so the table's list differs and
  the first play builds the queue.
- No setting or stored data changes.
