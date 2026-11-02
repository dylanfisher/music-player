# 0053. The track table's appearance settings and full-width album art

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0042](0042-window-layout-and-settings-sections.md) (Sections)

## Context

The owner wants the track table to look like Swinsian's: thin lines between the columns, short
rows, no alternating shading, and an Album Art column whose art fills the column's width and
spans the album's rows. Today's look has to stay the default, and the table already has an
Album Art column that draws a thumbnail in each row.

## Decision

- **Five settings under `appearance.`** in the config file: `columnLines`, `rowLines`,
  `alternatingRows`, `rowHeight` (compact 17 pt, Swinsian's; regular 18 pt, today's; large
  22 pt) and `artSize`. Their defaults are today's table. Like every Boolean and choice
  setting, each is a command, listed in View ▸ Track Table.
- **`artSize` chooses between today's thumbnail and full width**, rather than full width
  replacing the thumbnail. The row asked for both "an art size setting" and "defaults stay as
  today's look"; a choice between the two drawings gives both, and keeps a thumbnail per row
  for a table sorted by title, where full-width art would show only the top of each track's art.
- **Full-width art is drawn a row at a time.** An `NSTableView` cell can't span rows, so each
  row of the Album Art column draws its slice of the album's art: a square as wide as the
  column less a 2 pt inset, from the top of the album's first row. An album is a run of
  adjacent rows with the same album ID; a row with none is a run of its own. A row finds its
  run's start by looking back no further than the art is tall, so a long album costs no more
  than a short one, and rows below the art draw nothing. Art that isn't square fits inside the
  square. Resizing the column refits the slices on screen.
- **Full-width art loads at 512 px, 40 images kept** (about 40 MB); thumbnails load at twice the
  row height, 300 kept, so Large rows are sharp too.
- **An Appearance pane** in Settings holds the `appearance` section, Light or Dark included,
  instead of its section in General. With six settings it is no longer the two or three that
  0042 found too few for a pane, and General doesn't grow by five rows. The pane is the General pane's code showing one section and no config file buttons.
- **Only the track table follows the settings.** The play timeline keeps the look it has; the
  settings' summaries name the track table.

## Alternatives considered

- **One overlay view drawing each album's art over the table**, positioned by the rows' rects.
  Rejected: it would have to track scrolling, column moves, resizing, hiding and selection
  drawing by hand, where cells get all of these from the table.
- **Full width replacing the thumbnail, with art size as a number of points.** Rejected: the
  column's width is the art's size already, saved with the table's layout, so a second number
  would be a second source for it.

## Consequences

With Row Lines on, the lines cross the art. Deciding which art a row shows looks back through
the row cache, up to a few rows per row on screen, each time an image loads.
