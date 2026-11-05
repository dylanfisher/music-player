# 0094. A Toolbar settings pane, Swinsian's folder change options, and a status alone fills

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0067](0067-settings-layout-and-played-share.md) (the panes and sections),
  [0009](0009-scanning-and-watching.md) (what a scan removes and reads),
  [0087](0087-toolbar-status-and-window-title.md) (when the status is centered),
  [0089](0089-custom-status-items.md) (a Custom Status item's width)

## Context

The owner's feedback of 2026-11-04 night (phase 41e). Settings ▸ Appearance had grown to 20
rows in one box, each a label, a control and a gray line that often repeated the label. Swinsian
has two watched folder options, "Remove tracks from library when they disappear from watched
folders" and "Rescan tags when files in watched folders are modified", both on by default; every
scan here already did both, with no way to turn either off. And a status item alone in the
toolbar didn't fill it: a probe found that AppKit never widens the centered item past what fits
centered, so the status stayed at its 280-point minimum with no flexible space, whatever its
`maxSize`, and grew only to the 560 points it has beside one.

## Decision

**Two panes where Appearance was.** Appearance keeps two boxes, Theme (Appearance, Window Glass)
and Track Table (the lines, their colors, Playing Row Color, Alternating Rows, Row Height, Album
Art). A Toolbar pane after it holds Titles (Window Title, Toolbar Title Line), Toolbar Status
(Toolbar Status Layout and the Custom Status layouts) and Status Bar (its style and layout), in
the window's order from the top. Every one of these keys starts with `appearance.`, and renaming
them would lose the owner's settings, so each section lists its keys, as Network Folders does;
`appearance` itself is Theme's, so a new appearance key shows there until it's given a section.
Each pane names its sections (`SettingsWindowController.Pane.sections`), General shows the rest,
and the palette opens the pane whose sections hold a setting.

**The three Custom Status layouts share a row**: one label, Custom Status Layouts, one summary,
and a button each, Edit 1… to Edit 3…, which opens that setting's builder as before; each button
keeps its setting's title for VoiceOver. A row's `group` says which rows share a line. The
settings stay three, as 0089 chose.

**Shorter summaries.** Where the title says it, the summary says what the title doesn't: "A thin
line between the rows." for Row Lines, "Default is a light gray." for Playing Row Color. Color
wells are 44 points wide; they stretched across the row before.

**Folder Changes.** `library.removeMissingTracks` (Remove Missing Tracks) and
`library.rescanModifiedFiles` (Rescan Modified Files), both on by default, sit in a Folder
Changes box above Network Folders in Settings ▸ Watched Folders, and are toggles in the File
menu beside the network folders' two, as every setting command is in a menu. The scanner takes
`ScanOptions`:

- With removal off, a walk that finished leaves the tracks of files it didn't find in the
  index. With it on, nothing changes from 0009. Either way no file is touched, and a folder that
  is missing, lists nothing while the index holds its files, or vanishes or changes device
  during the walk removes nothing, so a NAS that drops off for a while keeps its tracks whatever
  the setting.
- With rescanning off, a known file whose size or modification time changed is counted
  unchanged and keeps its stored size and time, so it reads as changed at every scan and is
  read once the setting is on again. A file stored as unreadable is still read again: it failed,
  it didn't change.
- Rescan, Rescan All and the tag editor's own writes read modified files whatever the setting:
  someone asked for them, and the tag editor brings the index up to date by rescanning the
  folders it wrote. The watcher marks those folders and the next scan of each reads modified
  files. A running scan that leaves modified files doesn't count for a Rescan; the folder is
  scanned again after it. Removal follows the setting on every scan.
- A change of either setting restarts the watcher, as the other library settings do.

**A status alone fills the toolbar.** A status item with a flexible column takes all the room
the other items leave when no flexible space is in the toolbar, as before, and now also when
nothing but spaces is beside it. While it fills, the status isn't AppKit's centered item, since
AppKit won't widen a centered item; with another item and a flexible space it is centered and
at most 560 points, as 0087 has it. A Custom Status item alone between flexible spaces fills
too.

**Outlines while customizing.** While Customize Toolbar's sheet is open, the status and the
Custom Status items draw a 1-point rounded outline in the tertiary label color on their layers,
so one with nothing to show can be found and dragged out. The window's sheet notifications and
`customizationPaletteIsRunning` say when; both are on macOS 12, and NSToolbar posts nothing of
its own for the palette. The status bar isn't in the toolbar and has no outline.

## Alternatives considered

- **One long Appearance pane with titled boxes.** Rejected: about 1,100 points tall, past a
  900-point screen, and the toolbar's rows have little to do with the track table's.
- **Renaming the keys to give each section a prefix** (`toolbar.`, `table.`). Rejected: the
  owner's config would lose those settings under the pre-release rule, for a grouping a list
  of keys gives.
- **A popup of the three Custom Status slots with one Edit button.** Rejected: two clicks where
  a button each takes one, and the popup's choice would be state with no meaning outside the
  pane.
- **Removal off for automatic scans only, so Rescan still removes.** Rejected: the setting reads
  as "the library keeps missing tracks", and a Rescan that removed them anyway would surprise.
  Remove from Library takes them out by hand.
- **Rescanning off for the tag editor's writes too.** Rejected: the index would keep the old
  tags of an edit the owner just made, since the editor saves through a rescan.
- **Keeping the status centered and sizing it to the free width by hand**, on every resize.
  Rejected: AppKit already gives an uncentered item the room, and a status that fills has
  nothing left to center in.

## Consequences

- A setting added under `appearance.` lands in Theme until a section lists it; the sections'
  test lists every appearance key, so a new one is noticed.
- With removal off, a moved file is a new track beside the old one, whose stats aren't moved to
  it: move matching runs on removals (0022). Turning removal on moves them at the next scan.
- With rescanning off, a modified file is compared at every scan, which costs a stat already
  made, not a read.
- The outline's color is resolved when the sheet opens, so an appearance change while it's open
  keeps the old color until it opens again.
