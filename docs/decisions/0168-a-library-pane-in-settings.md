# 0168. A Library pane in Settings, and a pane's window resized after layout

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0042](0042-window-layout-and-settings-sections.md) (the Watched Folders pane,
  General's Library section), [0017](0017-settings-window.md) (the panes' snapshots)

## Context

The watched folders and their boxes were in Settings ▸ Watched Folders, and the Library section
(Show Library Health, the database, its snapshots and Snapshot Folder) was in General, so the
library's settings were in two panes. The owner chose one merged pane. Separately, opening then
closing the Snapshots disclosure left an empty strip at the top of the window.

## Decision

- **Settings ▸ Library** takes the Watched Folders pane's place in the toolbar, with the
  `books.vertical` symbol. From the top: the watched folders list and its buttons, then Folder
  Changes, Network Folders, Library Folder and Library, the box with the other `library.`
  settings, Show Library Health, the database and the snapshots. The Watched Folders pane is
  gone, and General keeps Sync, Receiver, Downloads and Other. The palette, the Watched
  Folders… command and `--snapshot-of library` open it.
- **The pane's title is the Library section's**, so the box and the pane share one name.
- **A pane's window is resized after the layout pass**, on the next turn of the main queue.
  The pane's frame-change notice, which resizes the window, is posted from inside the window's
  layout pass; a window resized there ends with its scroll view at the old height plus the
  change once more. After a close, the scroll view was shorter than the window, and the strip
  above it was empty; after an open it was taller, its top cut off. The clip view's scroll
  origin stayed at the top throughout.

## Alternatives considered

- **Resetting the clip's scroll origin after `fit()`**, as the plan first guessed. Rejected: the
  origin was already at the top; the scroll view itself had the wrong height.
- **Setting the scroll view's frame by hand after the resize.** Rejected: the layout pass that
  is still running sets it again afterwards.
- **A Snapshots pane of its own.** Rejected: the owner asked for one pane, and the snapshots
  are the library's.

## Consequences

The window follows a disclosure one main-queue turn later, which isn't visible. A test that
checks the window's height after a row shows or hides waits a moment first.
