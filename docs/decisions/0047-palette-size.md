# 0047. The palette takes simple-spotlight's size

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0016](0016-palette.md)

## Context

The owner asked for ⌘K and ⌘P to have the same width, height, row height, field font and corner
radius as the panel in `~/projects/simple-spotlight`, the owner's launcher. As with Searcher
([0012](0012-searcher-conventions.md)), its numbers are read from its code and its code isn't
copied. Its `SearchPanel` and `ResultRow` give: 680 points wide, a 56-point field row in 24-point
light system type, 48-point rows inset 6 points above and below under a 1-point line, and a
16-point corner radius. Its height follows the rows shown, up to its `maxResults` setting, 8 by
default.

## Decision

- **Both palettes use those numbers.** Width 680, field row 56, field font 24-point light, row
  height 48, radius 16, the rows inset 6 under a separator line.
- **The height is fixed at simple-spotlight's full height**, eight rows: 56 + 1 + 6 + 8 × 48 +
  6 = 453 points. simple-spotlight shrinks to the rows it has, starting at the field alone. The
  palette doesn't, because it lists rows from the first frame (⌘K its commands, ⌘P the library),
  so it is almost always full, and a panel that resized as results arrived would flash, which the
  owner reported as a bug in 24.1 and 24.2.
- **A long title still wraps and its row grows** past 48 points, as 0016's rows do: an album or
  track title can be longer than a launcher's app name, and cutting it would hide what tells two
  rows apart.
- Page Up and Page Down move by the visible rows less one, seven.

## Alternatives considered

- **Shrinking to the results, as simple-spotlight does** — rejected for the flashing above.
- **simple-spotlight's two-line rows**, title over subtitle with a 40-point icon — not asked for;
  the row keeps its layout and takes the height.
