# 0097. White text on a dark playing row, and a play that keeps the queue

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0092](0092-playing-mark-and-timeline-columns.md) (the playing row's text)

## Context

The owner's feedback of 2026-11-05 (phase 42b) asked for white text on the playing row when its
color (`appearance.playingRowColor`) is dark, in every column but not on a selected row. It also
asked that Enter or a double-click on a track the queue already holds in the same order, such as
the one after the playing track, start it as Next does instead of building the queue again.
Both left open what "dark enough" and "the same queue" mean.

## Decision

- **Dark is WCAG 2's contrast test.** White text goes on a color whose contrast with white
  beats its contrast with black, by relative luminance; the two are equal near a luminance of
  0.18 (between `#757575` and `#777777`). A color with opacity is first laid over the controls'
  background in the row's appearance, which is what shows through it. Only a chosen color
  counts: the default gray tint keeps the text as it is.
- **The row gives its cells the emphasized style.** `MarkedRowView.interiorBackgroundStyle` is
  `.emphasized` while the row is marked with a dark tint and isn't selected, the style AppKit
  gives cells on a selection with the keys. Text cells already draw the selection's text color
  for it whatever their own color, so every column, secondary and tertiary text included,
  turns white without each column knowing about the tint. A selected row keeps its
  selection's style. AppKit doesn't pass the style on for every change it depends on, so the
  row restyles its cells when its mark, tint, selection or appearance changes.
- **The same queue is the same list, unedited.** The browser model keeps the track IDs, in
  play order, of the list its last play queued, and the queue it read for them. A play from
  the same IDs in the same order gets a `PlayStart` that carries that queue. The app asks the
  engine to play the clicked entry in place (`play(entry:ifQueueIs:)`), which does so only
  while the engine's queue equals the carried one: set from that list and not edited since by
  Play Next, Add to Queue, a move or a removal, and not replaced from elsewhere. Anything else
  is refused, and the app replaces the queue as before. A library change forgets the kept list,
  since files may have moved.
- **In place is what Next does.** The engine moves to the entry's position and loads it, so the
  shuffle order stays, and the device output takes the load of its open next track instead of
  opening the file again, keeping what it had read ahead.

## Consequences

- The first play after a launch builds the queue even if the restored queue came from the same
  list, since the model has no kept list yet; from the second play on it's kept.
- An edited queue is rebuilt by a play from its list, which drops the edits, as before.
- A shuffled queue played in place stays in its shuffle order; a rebuild would shuffle again.
- No setting or stored data changes.
