# 0204. Focus mode, the main window changed in place

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0072](0072-window-chrome-and-status-bar.md) (Distraction-Free Mode)

## Context

The owner asked for a focus mode: the track table full screen, with only Title, Artist and
Album, in much larger text and always dark, but otherwise the track table, with the same rows,
sort, selection, playing row, double-click and keys. Escape or the command again leaves it, and
the window comes back as it was. The phase left it to the plan which tracks it shows.

## Decision

- **Which tracks:** the current view's. The phase asks for the same rows and selection, and
  for leaving to restore the selection, which only reads for the list already on screen. What's
  playing's source would be another list, and Show Current Track already goes there.
- **The main window changes in place.** View > Enter Focus Mode (⌥⌘F, in the palette too)
  hides the toolbar, the sidebar, the queue, the signal path, the browser's columns or a
  source's panel, and the status bar; shows only Title, Artist and Album, in equal widths that
  grow with the table; sets the window's appearance to dark; gives the table the keys; and
  enters full screen, unless the window is already in it. Leaving puts back each of those, the
  appearance the window had, the view that had the keys, and windowed mode if Focus Mode
  entered full screen.
- **Nothing it changes is saved.** Not the toolbar, sidebar, queue or status bar's
  visibility, the window's frame, nor the focus columns: the track table reports the columns it
  showed before, with the sort as it is now, so a sort chosen in focus mode is kept and saved.
  Its header menu is empty while it's on, and the View menu's toggles are off.
- **Leaving.** Escape, the command (Leave Focus Mode while on), leaving full screen by the
  window's control or menu item, or a source change to the play timeline, which takes the
  track table's place, all leave it. The command is off while the timeline shows.
- **Text size:** `appearance.focusFontSize`, 30 points by default, 2.5 times the Regular
  row's 12, from 16 to 96. Rows are half as tall again as the text, as Regular's 18-point rows
  are for 12-point text. A change applies while focus mode is on.

## Alternatives considered

- **A second full-screen window with its own table.** Rejected: it would be a second track
  table to keep in step with the first, for the rows, the sort, the selection, the playing row
  and the keys, which the phase asks to be the same.
- **Moving the table's view into a window of its own and back.** Rejected: the table's
  constraints, its status bar inset and the commands that act on the main window would all
  need putting back by hand.
- **What's playing's source as the list.** Rejected: focus mode would then open on another
  list than the one on screen, and leaving would restore a selection the user never saw.

## Consequences

- Quitting in focus mode saves the window as it was before it, since nothing it changed was
  saved.
- A reload of every row, as a row height or text size change makes, now keeps the selection,
  which `NSTableView.reloadData` dropped.
