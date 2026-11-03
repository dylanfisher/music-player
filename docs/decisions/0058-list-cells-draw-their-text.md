# 0058. List cells draw their own text

- **Date:** 2026-11-02
- **Status:** accepted

## Context

The owner finds scrolling the track table, and dragging its scroll bar above all, slower than
Swinsian's. A new benchmark scrolls every fixture row a screenful at a time, as a knob drag
does, with the Album Art column shown, and times each step from the scroll to the layers
committed: 15.2 ms p95 on Apple Silicon before any change, against one 60 Hz frame. Sampling
that run, the app's own work per row (the row cache, the column's text, the art request) was
about 4% of the main thread. The rest was AppKit's: drawing the text, about half, and on each
reused row a constraint pass over every text field (its intrinsic size measured again for the
new string), then a layer per text field to update and commit.

## Decision

- **A list cell is a `TextCell`,** an `NSTableCellView` that draws its one line itself, cut off
  at its end, in the selection's text color when its row is selected and the list has the
  keys. No text field, so no constraint pass and no layer per field. The play timeline uses it
  too, since the two lists made their cells with one function.
- **The art thumbnail cell keeps its image view, placed by its autoresizing mask** instead of
  four constraints. (0065 replaced the thumbnail with album art drawn by its cell.)
- **Each track row draws into one layer** (`canDrawSubviewsIntoLayer` on the row view), so a
  row of cells costs one backing store, not one each.
- **The scroll view is layer-backed explicitly,** which responsive scrolling needs, rather than
  only through the window.

After: 9.8 ms p95, median of three runs.

## Alternatives considered

- **`canDrawSubviewsIntoLayer` on the cells, keeping their text fields.** Tried first: on macOS
  26 a text field keeps a layer of its own inside a cell that draws its subviews into its
  layer, and still runs its layout pass. Laying the fields out by mask alone brought the p95
  to about 14.7 ms.
- **Fetching row pages and formatting text ahead of the scroll, off the main thread.** A drag
  jumps anywhere, so the page under the knob has to be read when it's reached anyway; a page is
  one primary-key lookup per row, and both together were under 2% of the samples. Not worth a
  second thread's state.
- **A cell-based `NSTableView`.** Deprecated, and the full-width art and the marked row are
  built on view-based rows.

## Consequences

A cell's text is no longer a text field, so VoiceOver reads it through the cell's
accessibility value, and nothing can select or edit it in place, which nothing did. Text
drawing is now most of a step's cost; making it cheaper means drawing fewer columns or
caching drawn text, neither of which this decision takes on. The benchmark flushes each step
straight after the last, which adds a wait for the render server that a real drag spreads
across frames, so its figure errs high.

A constraint anywhere in the track table's view puts the window under Auto Layout, which gives
every cell constraints to solve again. So views placed over the table, such as History's
"Nothing played yet", are laid out by frame and autoresizing mask.
