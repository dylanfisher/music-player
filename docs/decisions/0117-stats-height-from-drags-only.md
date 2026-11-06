# 0117. Listening Stats' height: a least height, placed after layout, saved only from a drag

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0102](0102-listening-stats.md) (its own height)

## Context

The owner's feedback of 2026-11-06 (part 50a). With Show Browser off, Stats opened at no
height, and the owner had to drag it open. The probe found two causes. The timeline hides the
whole split over the track table; going from it to Stats unhid the split and placed the
divider in the same pass, while the split still had its hidden bounds, so the table's 120
points of room put the divider at 0. And the split saved the slot's height on every resize
the browser didn't make itself while the window showed, layout passes included, so that 0
was saved, with nothing in `statsHeight`'s range (`0...2000`) to refuse it.

## Decision

**A least height.** `AppState.statsHeightRange` is `130...2000`: the panel's header and its
first row of cards, the Totals card, fit in 130 points; a test lays the panel out at that
height and checks. A saved height out of the range is discarded and the default used. While
Stats shows, the split's delegate keeps the divider at least that far down. The columns keep
`0...2000`, where 0 hides them.

Library Health shares the columns' height, so it has a least height of its own,
`HealthPanel.leastHeightPoints`, 110 points: its header, Analyze Library's line and a row of
tiles; a test lays the panel out at that height and checks. It opens at the columns' height or
that, whichever is more, and while it shows the delegate keeps the divider at least that far
down. A drag of it saves the columns' height, as before.

**Placed after layout.** The browser lays out the split's superview before it moves the
divider, and the split after, as `MainSplit.restore` does, and records the height the slot
got, which a short window can make less than asked, so the next change of panel tries again.

**Saved only from a drag.** The split is a `DividerDragSplitView`, which sets `isDragging`
around `NSSplitView.mouseDown`; the split tracks a drag inside that call until the mouse goes
up. A resize while it isn't set, a layout pass, a window resize or the browser's own placing,
saves nothing. This applies to the columns' height too.

## Alternatives considered

- **`NSSplitViewUserResizeKey` in the resize notification's user info.** A drag posts it as 1
  and `setPosition` as 0, but the key isn't documented.
- **`NSApp.currentEvent` being a mouse drag.** A drag of the window's edge is one too, and
  the slot shrinks when the window gets too short for it.
- **A drag through the split's own mouse tracking in the tests.** It works with events posted
  ahead of `mouseDown`, but the test run ends at the next suspension; the tests set
  `isDragging` around `setPosition` instead.

## Consequences

- A height saved as 0 before this is discarded at the next launch; Stats opens at 380.
- Dragging Stats' divider up stops at 130 points.
- Library Health opens at 110 points over columns dragged shut, and its divider stops there; a
  drag of it leaves the columns at least that tall until they're dragged shut again.
