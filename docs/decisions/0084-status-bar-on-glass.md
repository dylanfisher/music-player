# 0084. The status bar centered on the window, over the rows, on glass

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0072](0072-window-chrome-and-status-bar.md) (the status bar's material, glass),
  [0065](0065-album-art-fit-hover-and-viewer.md) (the hover's area, the viewer)

## Context

The owner's feedback on the release build at c4c8c65 (phase 36): the status bar's middle
should stay centered on the window, under its title; the bar should be liquid glass, which it
never looked like because nothing scrolled behind it (0072); toggling a status bar part, Art
alone in particular, shrank the window and moved the sidebar; the bar's art did nothing on a
click; the art hover needed the pointer over the image itself; and after glass went on and off,
every row had faint lines between it and the next.

## Decision

**The bar stays over the browser, and its middle is centered on the window by a constraint.**
`CenteredRow` holds three views: the scan progress at the leading edge, the problems button at
the trailing one, and the parts in the middle, whose center is tied to the window content
view's center. The full-width option the plan offered, the bar under the sidebar and the queue
too, was not needed: a constraint across the view tree centers the middle wherever the bar
sits, so the sidebar's width, a hidden sidebar or queue, and the scan text's width don't move
it. The middle grows evenly to both sides when the seek bar or the totals take the free width,
and stops at the nearer edge view; when even that can't keep it centered, it moves aside rather
than overlap. Phase 37's columns can reuse the row: its middle column is this middle.

**Nothing in the bar can resize the window or move a divider.** Every constraint that places
or sizes the middle, and every truncating label's resistance to truncation, is below 250, the
lowest priority at which the main window's split panes keep their widths, and so below
`NSWindow`'s 500. Text truncates first, then the middle moves aside, and when even the bar's
fixed parts don't fit, such as the art, the seek bar's least width and the scan indicator at the
window's narrowest with the sidebar and the queue open, they overlap rather than push. Before,
the bar was stacks pinned edge to edge, and with Art alone nothing in it could stretch, so the
stacks held the browser, and the window with it, to the art's width (36.4). A first version
kept the middle clear of the edge views at required priority and centered it at 490, which
still took width from the sidebar at 720 points wide.

**Rows scroll under the bar.** The bar lies over the bottom of the track table and the
timeline, and their bottom content inset is the bar's height while it shows, so the last row
still scrolls clear. On macOS 26 and later the bar is an `NSGlassEffectView`, edge to edge with
no corner radius; on 12 to 15 it keeps the title bar material, now blending within the window
with the rows under it. The window's glass no longer switches that material to blend behind
the window, which would hide the rows. Paging, centering a row and scrolling by rows count the
inset.

**Glass puts the frame and the dividers back.** Glass inserts the full-size content view style
and takes it out. AppKit keeps the content's size across that change, so the frame shrank by
the toolbar and grew back, and each split shared the change out between its panes: the queue
came back a fraction of a point narrower and the browser's divider moved, both off the pixel
grid. That was measured; the faint lines themselves couldn't be seen here, since snapshots draw
views rather than the composited layers, so that rows between pixels draw them is inferred.
`WindowGlass` now saves the frame and every divider beside two open panes, and puts them back
after the change. A test builds the real main window twice and compares the frame, every
split's panes and every list's grid, background, row and alternating settings with a fresh
window after glass on and off.

**Alternating rows on glass are a translucent tint**, the text color at 5%, as the background
color of every other row view, where AppKit's opaque alternating colors stay off. The timeline,
which always alternates, does the same. Drawing the tint in the table's
`drawBackground(inClipRect:)` was tried: the override alone, with nothing drawn, made trackpad
scrolling cost 64 to 69 ms a frame against 8 to 13.

**The bar's art opens the viewer** that row art opens, on the playing track's art. Like row
art's, it stays open across a refresh while that track is listed with the same art and album
(phase 35). **The art hover shows from anywhere in an
album's art cells**, the space beside a scaled-down image included.

**Settings describes glass** as turning the whole player into translucent glass.

## Alternatives considered

- **The bar spanning the whole window, under the sidebar and the queue.** Rejected: centering
  works without it, and rows of three lists, the sidebar's on its own material, would scroll
  under one bar.
- **A full-size content view whatever the glass**, so no style mask ever changes. Tried and
  rejected: AppKit then lines the toolbar and the title up with the sidebar in the plain window
  too, and the title leaves the window's center line, where the bar's middle goes.
- **Laying the bar out by frame in `layout()`.** Rejected: the middle's fitting width changes
  with the playing track's title, which a frame layout would have to watch for; constraints
  follow it.
- **A floating glass capsule** instead of an edge-to-edge bar. Left for phase 37's builder,
  which decides the bar's shape.

## Consequences

- With glass on, AppKit centers the title over the area beside the sidebar, so the bar's middle,
  centered on the whole window, sits left of the title by half the sidebar's width. A known
  limitation, for phase 37's builder to address.
- The window and live resize benches run with the bar over the rows, glass off, so on macOS 26
  and later the bar is an `NSGlassEffectView` over them. The bar over the rows costs the scroll
  benches no more than the bar below them: measured one after the other on the build Mac, the
  scroll-bar drag's p95 was 13.65 and 13.44 ms with the bar over the rows, 13.01 and 13.01 ms
  with it below as before, 13.39 ms over them on the title bar material and 13.40 ms without the
  window centering; compact rows were 10.91 and 10.81 ms against 10.78 and 10.69 ms. The
  phase's final code measured 13.38 and 10.84 ms. These
  benches swing with the machine's load: a run while other processes kept 8 of the 10 cores busy
  measured 25.5 ms for the drag, so compare them only one after the other on an idle Mac.
- The 2015 MacBook Pro shows the material fallback; that it blends with the rows under it is an
  owner check there.
