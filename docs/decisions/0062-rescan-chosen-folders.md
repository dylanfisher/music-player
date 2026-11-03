# 0062. Rescan for the chosen watched folders, and Rescan All

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0040](0040-gentle-network-rescans.md) (Rescan Now),
  [0042](0042-window-layout-and-settings-sections.md) (the Watched Folders pane)

## Context

Row 26.2 asks for the Watched Folders table's Rescan Now to become "Rescan All", and for a
"Rescan" that scans only the selected folders, in the buttons and the table's context menu. The
owner's library is on a NAS, where a whole rescan of every folder takes minutes; one folder that
changed shouldn't cost that.

## Decision

- **Rescan Now is renamed Rescan All** everywhere it shows: the File menu, the palette, the
  pane's button and its context menu. The command ID stays `rescanNow`, so shortcuts and
  `music-player rescanNow` keep working. It still scans every folder as 0040 says.
- **Rescan scans the chosen folders whole**, by the same path as Rescan All
  (`WatchState.rescan(wholeFolders:)`; `rescanEverything` passes every folder). So it ignores the
  poll timer and the playback pause, waits while a track starts, and a running whole scan of a
  chosen folder counts for it and stops waiting for playback, as 0040 has for Rescan All.
- **A folder is found by its value in Settings**, then scanned where the watcher found it (a share
  may be mounted elsewhere, 0028). One no longer in Settings when the request reaches the
  watcher is skipped and logged: the watcher is restarting without it.
- **The context menu acts on the clicked row**, with the rest of the selection when the clicked
  row is in it, as Finder does. With no clicked row it acts on the selection.
- **Rescan is not a registry command.** It needs the folders chosen in the table, which no other
  place has, so it isn't in ⌘K, the menus or links.

## Alternatives considered

- **Rescan as a command taking a folder path**, for ⌘K and links. Rejected: links can't run Rescan
  All because it overrides the playback pause (0040), and the same holds for one folder.
- **Rescan scanning only what changed** (the subtrees FSEvents or a poll found). Rejected: the
  user asks for it when they think the index is wrong, so the whole folder is walked.

## Consequences

Rescan All's name differs from its command ID. A Rescan of a folder whose whole scan is already
running doesn't start a second one; it only lifts the playback pause on the running one.
