# 0089. Custom Status items: builder layouts as toolbar items

- **Date:** 2026-11-04
- **Status:** accepted
- **Amends:** [0055](0055-customizable-toolbar.md) (the toolbar's items),
  [0085](0085-status-bar-builder.md) (the toolbar status's layout and the builder's bars)

## Context

The owner asked whether Customize Toolbar could offer placeholder items that are then laid out
with the bar builder, so more than one now-playing bar can sit in the toolbar, each built as
the owner likes. The toolbar had one such item, Status, laid out from
`appearance.headerStatusLayout` and centered on the window (0087). `NSToolbar` shows an item
with a given identifier at most once, other than its own spaces, so one item can't be added
several times with a different layout each time.

## Decision

**Three numbered slots.** Customize Toolbar offers Custom Status 1, 2 and 3 right after Now
Playing. They are `ToolbarItem` cases (`customStatus1` to `3`), saved in `state.json`'s
`window.toolbarItems` like every item, and none is in the default set. Each can go anywhere in
the toolbar, beside the status or without it. Only the status stays the centered item.

**Three settings, one per slot**: `appearance.customStatus1Layout` to `3`, titled "Custom
Status 1 Layout" and on, each a `BarLayout<HeaderPart>` with the header's parts, decoded and
checked exactly as `appearance.headerStatusLayout` is. They follow Toolbar Status Layout in the
schema, so Settings ▸ Appearance lists their rows there, and each row's Edit Layout… opens the
same builder in its own window. The default is Swinsian's centered line: the Title Line over
the seek bar, stacked in a flexible center column, centered.

```json
"appearance.customStatus1Layout": {
  "leading": [],
  "center": { "parts": ["titleLine", "seek"], "width": "flexible", "alignment": "center",
              "stacks": true },
  "trailing": []
}
```

**The Title Line shares the template.** A slot's Title Line reads
`appearance.headerTitleFormat`, the same template as the status's, so the line reads the same
wherever it shows; a slot that wants another line uses other parts.

**Each slot has its own views on the one bar.** `NowPlayingBar.customStatuses` holds a
`HeaderStatus` per slot, each with its own art, labels and `SeekBox` laid out from its own
setting. The bar fills them with the status on every update from the one model, gives them the
art, the times and the seek position, and wires their seek bars to the same seek. With nothing
playing they hide their rows, as the status does (0085). The toolbar takes the slots' views as
it takes the status's, and the app lays a slot out again, with its drawing and its size, when
its setting changes.

**Width follows the layout.** A slot whose columns are all fixed is exactly as wide as they
are, plus the status's 10-point spacing between them (`HeaderStatus.fixedWidthPoints(of:)`),
so it takes no more room than it draws. A slot with a flexible column is sized as the status
is: 280 points at least, up to 560 while a flexible space shares the toolbar, or the free width
without one. Its height is its view's fitting height, as the status's is.

**The sheet draws each slot from its layout**, with the placeholder track and the owner's
template, as it draws the status, at 70%. A layout of fixed columns is drawn at its own width,
the status's drawing included.

## Alternatives considered

- **One setting holding the three layouts**, as the plan first said. Rejected: the builder,
  its row and its window work on one `.barLayout` setting by its key and save patches to it,
  and the pane shows one row per setting. A list would need the builder to edit one element of
  a list and the pane to show three rows for one setting; three settings need no change to
  either.
- **A `NowPlayingBar` per slot on the same model.** Rejected: a bar follows the engine,
  applies each update to its model and runs the position timer and the seeks, so three bars on
  one model would apply every update and tick three times, and each would set the window's
  title. The slots' views hang off the one bar instead, which is what "fed by the same model"
  needs.
- **One item added many times with a layout per instance.** Not possible: AppKit shows an
  item at most once, and an identifier per instance would need the toolbar to invent and save
  identifiers with no row in Settings to edit them from.
- **A Title Line template per slot.** Not now: three more settings for a line the owner
  hasn't asked to differ; a slot can show the Title, Artist and Album and Format parts instead.
- **Centering a slot too.** Rejected: `centeredItemIdentifiers` centers them as a group, which
  would pull the status off the window's center when a slot sits apart from it.

## Consequences

- More slots mean one more case, setting and switch arm each; three cover the owner's layouts.
- A slot with a fixed layout can't shrink in a narrow window, as a fixed status column can't.
- The slots update with the status on the main thread at the same 0.5-second tick; three more
  bars add labels to set, not timers.
- The snapshots show the slots empty in the toolbar, since nothing plays in a `--snapshot` run;
  the slots with a track playing were checked by tests, not on screen.
