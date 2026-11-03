# 0065. Album art scaled to fit or full width, shown whole on hover, opened on click

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0053](0053-track-table-appearance.md) (`artSize`),
  [0058](0058-list-cells-draw-their-text.md) (the thumbnail cell)

## Context

The owner reported that the Album Art setting's Thumbnail and Full Width had no effect: art was
always full width. Phase 29 looked for the cause first. The setting is read in one place
(`WindowSettings`, `TableAppearance(settings)`), applied at launch by
`LibraryBrowser.setTableAppearance`, and again on every change of an `appearance.` key through
`settingsChanged`; snapshots of this build with each value at launch, and after editing the
config file while the app ran, drew a thumbnail per row and full-width art. No code path ignores
it, so the report couldn't be reproduced; it may have come from an older build or a config file
with a problem, which holds every change back until it's fixed. What the owner wants instead is
clear: a choice between art scaled to fit and art always full width, art edge to edge with no
row highlight beside it, the whole art on hover, and the art large on a click.

## Decision

- **`appearance.artSize` is `fit` (Scaled to Fit, the default) or `fullWidth`.** Both draw the
  album's art once across its rows, from the top of its first row (0053). Full width fits the
  art in a square as wide as the column, and the next album's rows cut it off. Fit scales that
  square down to the album's rows, centered across, so a short album shows all its art. The
  thumbnail per row is gone, and with it its image-view cell (0058). A config that still says
  `thumbnail` no longer matches: pre-release, it shows the banner until the value changes.
- **Edge to edge.** `KeyTableView.edgeToEdgeColumn` makes the Album Art column's cells fill the
  column's whole rect, the spacing and the full-width style's padding included, through
  `frameOfCell(atColumn:row:)`, the table's own hook for placing cells. Overriding the cell's
  frame setters didn't work: the table places cells by more than one path.
- **Art loads at the column's pixels**, the next power of two from 64 up to 1,024 at twice the
  column's width, 40 images kept. The loader is replaced only when a resize crosses a power of
  two. At the default 34-point column that is 128 pixels, smaller than 0053's 512.
- **Hover** shows `ArtHover`, the whole art as wide as the column from the top of the album's
  first row, over the rows. It is a subview of the table placed by frame, so it scrolls with the
  rows and adds no constraints (0058). A tracking area on the table moves it; it hides when the
  pointer leaves the art and the overlay, and on a reload, a resize of the column or a change of
  the setting. Scrolling carries it with its rows until the pointer next moves.

  Amended 2026-11-03 (phase 30b). The table adds row views as it draws them, above the hover,
  so the art cells of rows below an album drew over its hover; only the lowest album's hover
  showed whole. Each showing moves the hover to the top of the table's subviews. Its hot area is
  its frame over the album's own rows, not the whole frame: the pointer on the next album's rows,
  under the hover, hovers that album at once instead of keeping the first until the pointer
  leaves the art column.

  Amended 2026-11-03 (phase 36, [0084](0084-status-bar-on-glass.md)). The pointer anywhere in
  an album's art cells shows the hover, not only over the drawn image.
- **A click on the hovered art opens `ArtViewer`**: a borderless window over the screen, the art
  centered over a dimmed backdrop, as large as the screen's visible area allows, upscaled if it
  must be. It shows the art it had at once and replaces it with the art decoded off the main
  thread at the screen's longer side in pixels. A click anywhere or Esc closes it, and so do the
  main window closing, the app resigning active and a reload of the rows, since it floats over
  every window. A decode that fails is reported as the browser's other failures are, and the
  first art stays; one that ends after the viewer closed is dropped. A click on the status bar's art
  opens the playing track's art in the same viewer (phase 36).

## Alternatives considered

- **Keeping the thumbnail as a third choice** — rejected: the owner asked for the two, and the
  hover shows any album's whole art in either.
- **A Quick Look panel for the large art** — rejected: it previews files, and the art is inside
  one at an offset; it would need a temporary file per click.

## Consequences

Row Lines still cross the art. The viewer covers the screen the window is on.
