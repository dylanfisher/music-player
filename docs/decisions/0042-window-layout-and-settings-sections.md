# 0042. Watched folders in Settings, Settings in sections, the window's panels as split items

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0017](0017-settings-window.md) (the watched folders' row),
  [0034](0034-folders-and-library-health.md) (Folders)
- **Amended by:** [0099](0099-library-health-panel.md): a source's panel takes the columns'
  place, at their height, whatever Show Browser says.
  [0062](0062-rescan-chosen-folders.md): the pane's Rescan
  Now is Rescan All, beside Rescan for the selected folders.
  [0067](0067-settings-layout-and-played-share.md): titled boxes, Sync and Network Folders
  sections, and the longest key prefix wins. [0067](0067-settings-layout-and-played-share.md):
  titled boxes, Sync and Network Folders sections, the longest prefix wins.
  [0168](0168-a-library-pane-in-settings.md): the Watched Folders pane becomes Settings ▸
  Library, which takes the Library section from General too, as Browsing and Database boxes.
  [0177](0177-art-viewer-settings-panes-get-info-steps.md): Watched Folders is a pane of its own again, after Library.

## Context

The owner tried the app on the 2015 MacBook Pro (macOS 12) and asked for five changes: a way to
hide the genre, artist and album panes; no line left behind by a hidden queue, and no queue
coming back when the window is resized; a sidebar edge that draws cleanly; the watched folders
out of the sidebar and in Settings, in a group of their own; and a Settings window in a few
clear sections with one short line per setting.

## Decision

- **Split items.** The sidebar, the browser and the queue are items of an
  `NSSplitViewController`. Hiding one collapses its item, which hides its divider; a plain
  `NSSplitView` drew the hidden queue's divider at the window's edge, and a drag there to resize
  the window dragged the divider and opened the queue. The sidebar is a sidebar item, which
  draws the sidebar material, in place of the sidebar's own `NSVisualEffectView`. The items'
  minimum and maximum widths are the ranges the state file accepts. Neither collapses from a
  drag, so the saved Show Sidebar and Show Queue always match what shows.
- **Show Browser (⌘B)**, iTunes' key for its column browser, hides the panes and their divider.
  Hiding them selects All in each first (no query when they're already at All), so nothing
  hidden narrows the table, and they show again at All. `window.browserVisible` keeps the choice, as `window.queueVisible` does.
- **Watched folders leave the sidebar**, and folder browsing with them: the sidebar has the
  library's group and the playlists. The `.folder` source, `FolderTree` and their query are
  gone. Settings ▸ Watched Folders lists each folder with its kind and how often it's rescanned,
  with Add…, Remove… and Rescan Now; ⌘O still adds one over the main window. Remove asks first,
  over the Settings window, and takes the folder out by its place in the setting. Scan
  progress and problems were already in the status line and stay there.
- **Sections.** General groups its rows by key prefix: Playback (`output.`), Library
  (`library.`, `sync.`), Receiver (`receiver.`) and Appearance (`appearance`). A key no section
  claims goes under Other, so a new setting still appears with no UI code; a test keeps the
  app's own settings out of Other.
- **One short sentence per setting.** Each summary is one sentence of at most 12 words, and a
  test holds it there. The same text is the config file's comment, so the file's comments are
  short too; its "Takes …" line still says what each value takes.

## Alternatives considered

- **Keeping folder browsing in a sidebar group of its own**, without the add and remove
  buttons. Rejected: the owner asked for the watched folders out of the sidebar, and the
  folders' rows were the watched folders.
- **Keeping the panes' selections while hidden.** Rejected: the table would be narrowed by a
  selection nobody can see, with nothing saying why tracks are missing.
- **A toolbar pane per section.** Rejected: most sections hold two or three settings, and a
  pane each would be six toolbar items for eleven settings.
- **Fixing the plain split view's delegate** to hide the divider and skip its limits for a
  hidden view. Rejected: the split view controller does both, and draws the sidebar's material.

## Consequences

A saved folder source no longer decodes, so a state file holding one is discarded whole once,
window layout included, as any state that doesn't match is. Long explanations, such as the sync folder's format, now live in
the README and the ADRs rather than the config file's comments.
