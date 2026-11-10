# 0176. The tagger keeps its album list's columns and its sheets' order

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md) (the sheets'
  layouts, which this extends), [0158](0158-every-window-keeps-its-frame.md) (every window keeps
  its frame), [0146](0146-staged-tag-writes.md) (the tagger opened from Downloads)

## Context

The owner asked, on 2026-11-09, for the tagger's album list to sort by any column and to keep
its column widths between launches, and for the window choosing a release to keep its size,
place and columns, from Downloads' Open in Tagger too.

A test that shows the tagger, widens a column and opens a second tagger with what the first
saved found why the widths went: nothing recorded them. The sheets kept theirs (ADR 0136), but
the window's own table had no record, and the divider beside it always started at 340 points,
so widths left at a wider pane wouldn't have fit either. Open in Tagger's tagger was made
without the saved layouts and saved nothing, so its sheets opened at their own sizes every time.
And no table kept its column order, though each lets a header be dragged.

## Decision

- **One record of a table's columns,** `TableLayout` in `Core/Settings`: widths and order by
  column name, and the sort. A sheet's layout is its size and one of these; the album list's is
  its pane's width and one of these. One `NSTableView` apply and record in the tagger serves
  both. A column the table no longer has is ignored, and one not listed keeps its width and
  comes after those that are.
- **The album list is kept with the sheets,** as `albumList` in `discogsTagger.sheets`, so it
  goes through the plumbing the sheets have: one setting, one closure, one copy per tagger. The
  type keeps its name, `TaggerSheetLayouts`.
- **Saved as it changes,** not as the window closes: a column's resize or move, a sort, a drag of
  the divider. The window can stay open until quit. The layout saver coalesces the steps of a
  drag. It's applied once the window's frame is placed (ADR 0158), the divider first, then the
  columns, so the table's resizing to the frame doesn't spread the widths, as Downloads does.
- **The sort is the model's:** Album, Files, Match or Review, either way; equal albums, and no
  sort, keep the artist-then-title order the list had. An album with no confidence sorts under
  every one. Review sorts by its cell's text.
- **The two taggers share one copy.** Each change from either goes to both and to the state
  file, and a tagger made later starts from a live one's copy, since the file's write waits a
  second. Without this, one tagger would save its older copy over the other's change.
- **Other Releases and Look Up share a layout:** the same sheet and columns, Look Up with a row
  of fields above them. A sheet has no position of its own; it opens over the tagger's window,
  which keeps its frame (ADR 0158).
- **The setting's shape changed:** a saved one, with no `table` and no `order`, is discarded
  once, pre-release.

## Alternatives considered

- **AppKit's `autosaveTableColumns` and the split view's `autosaveName`:** user defaults, which
  [ADR 0055](0055-customizable-toolbar.md) keeps window layout out of, and a second store
  beside `state.json`.
- **A setting of its own for the album list:** a second closure and saver path through the
  tagger and the app for the same kind of fact.
- **A column order field beside the flat widths:** the album list would have repeated the
  widths, order and sort fields; nesting them is one definition.

## Consequences

The Library Problems table (phase 68) and any later table can keep its columns with a
`TableLayout`. The Downloads window keeps widths only, through `ColumnWidths`; it can move to a
`TableLayout` if it gains a sort or its order matters.
