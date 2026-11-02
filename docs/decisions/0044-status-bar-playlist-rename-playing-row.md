# 0044. A readable status bar, playlists renamed in place, and a marked playing row

- **Date:** 2026-11-01
- **Status:** accepted

## Context

Three pieces of owner feedback on the main window. The status line under the track table, in
the small font and secondary color, was too faint to read at a glance. Playlists could be
renamed only through File ▸ Rename Playlist…, a sheet, and the sidebar had no context menu. The
track table didn't mark the playing track at all, and the queue marked it only with a ▶ and a
bold title, which the selection's blue drowned out.

## Decision

**Status bar.** The bar uses the window's normal text size, 6 points of padding top and bottom
and 10 at the sides. It has three parts: the counts of what the list shows in the label color;
the scans, in the secondary color after a small progress bar; and, at the trailing edge, an
inline button with a warning symbol whose title is the problem count ("3 files and 1 folder with
problems"), which opens the Problems window. The bar is determinate only once every running
scan has listed its folders, since until then what it has to read still grows; before that it
moves on its own. Notices that count no file or folder keep the old "Show Problems" title.

**Renaming in place.** A click on the name of the playlist already selected starts editing the
name in its row, as in Finder: the edit waits out the double-click interval and is dropped if a
second click comes or the selection moves. Return on a selected playlist row starts it too,
taking Return from Play Selection while the sidebar has the keys. Return keeps the new name,
Esc puts the old one back, and an empty or unchanged name changes nothing. The rename goes
through the same browser call as Rename Playlist…, which keeps its sheet for the menu and ⌘K.

**Context menu.** Each playlist row has Rename, Duplicate, Delete… and, for a smart playlist,
Edit Smart Playlist…. It acts on the row right-clicked, which needn't be the selection, and
doesn't select it. Delete… asks with the same sheet as Delete Playlist…; there is no undo,
since the app has none for playlists.

**Duplicate Playlist** is a command, so it's in the File menu and ⌘K, for the playlist shown.
The copy is named as Finder names one, "Mix copy", then "Mix copy 2", comparing names without
case as the sidebar sorts them. It keeps a manual playlist's entries in order, those whose file
left the index among them, or a smart playlist's rules, and is shown. A playlist whose rules
this build can't read isn't offered, since its copy couldn't be shown either.

**Playing row.** The row of the track the engine has loaded, playing or paused, is drawn with
the accent color at 16% across it and a 3-point accent bar at its leading edge, in the track
table and the queue. Over the selection the bar takes the selected text's color while the list
has the keys, so a selected playing row still reads as both. The queue keeps its ▶ and bold
title. The row view, `MarkedRowView`, is one class in DisplayText, the lowest module both
features import, in a file of its own as map.md asks of AppKit in a primitive. It knows only
that a row is marked, not why.

## Alternatives considered

- **A spinner instead of the progress bar** — rejected: a long NAS scan reads for minutes, and a
  bar that fills says how far along it is.
- **Rename Playlist… editing in place too** — rejected for now: the menu item's ellipsis promises
  a sheet, and the sheet works when the sidebar is hidden.
- **Selecting the right-clicked row** — rejected: it would change the list shown just to open a
  menu, and Music.app doesn't.
- **A hue of its own for the playing row**, such as yellow — rejected: the accent color follows
  the system setting and both appearances, where a fixed hue would clash with some accents.
- **A copy of the row view in each feature** — rejected: two lists drawing the same mark is one
  fact, and a third list would make it three.

## Consequences

The bar is a few points taller, which the default window still fits at 1440x900. Return in the
sidebar no longer plays the selection while a playlist row is selected. Esc while a name is
being edited goes to the field first; a window-wide Esc handler added later has to leave it to
the field editor.
