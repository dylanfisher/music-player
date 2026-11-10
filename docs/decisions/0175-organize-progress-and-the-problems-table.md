# 0175. Organize shows its progress, and Library Problems is a table in a normal window

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0164](0164-keep-files-organized.md) (when Organize Selected Files asks, and its
  result line), [0059](0059-problems-window-actions.md) (the window's rows)
- **See also:** [0158](0158-every-window-keeps-its-frame.md) (window frames),
  [0169](0169-approve-at-once-and-manual-upgrades.md) (a sheet that opens before its work, and
  column widths kept in `state.json`)

## Context

The owner asked on 2026-11-09 (phase 68): Organize Selected Files should open its confirmation
at once and count with live progress, Cancel working while it counts; once confirmed, the
status bar should show how many files are left and the current one, then one result line;
Library Problems should stop floating over other windows; and its list should be a standard
table, a column per piece of a problem, sortable, with column widths and the frame kept.

Before this, the command read every selected file's tags, from the NAS for most of the
library, before its `NSAlert` opened, and the renames ran on the tag writes' queue with
nothing on screen until the carry ended. The Problems window was a utility panel with one
column of lines.

## Decision

**The sheet first.** Organize Selected Files opens a sheet of its own as the command runs,
before the selection's paths are read: "Checking the Selected Tracks…", "Checked 120 of 2,340
tracks · 80 files to rename so far" and a bar. `layoutMoves` tells a closure after each path
and asks a stop check before each; Cancel sets the stop, so the count ends before the next
file is read, and nothing is renamed. Once counted, the sheet's text becomes the question it
asked before ("Organize 1 File?" and what's left where it is) and Organize appears. A count
that finds nothing to move closes the sheet and reports as before, in the status bar and the
Problems window: there is nothing to answer.

**Progress while it renames.** `moveToLayout` tells a closure before each file and once after
the last; `TagEditing.organizing` brings it to the main thread, and the status bar's activity
line shows "Organizing files: 2,328 left · Album/01 Song.flac", the file by its folder and
name, with the bar. After the last rename it says "Organizing files: finishing" while the
folders are tidied, the journal follows and the stats are carried, until `finishOrganizing`
clears it. Keep Files Organized's renames after a save show the same way. The result line is
"Organized 2,340 files; 3 problems", the problems being every row the Problems window gets for
the run; the Problems window opens only when there are any, as before.

**A normal window.** Library Problems is a titled, resizable, miniaturizable `NSWindow`, not a
utility `NSPanel`: it goes behind other windows and apps' like a document window. Its frame is
kept as before (ADR 0158).

**A table.** Each row has a kind, the path it's about, the detail and, looked up from the index
by that path when the window lists the rows, the track ("Artist – Title"). The columns are
Kind, Track, File (the name), Folder (the rest of the path) and Detail. Rows made from
structured sources take their parts from them: a stored file issue (its failure said plainly
first, "the file is damaged: …", a warning's kind in words), a folder's scan issue, a failed
scan, a health check's lines (the check's title as the kind) and an import's misses (the
missing track's path). The rest are lines of the form "<path>: <detail>", split at the first
": " when the line starts with "/", and their kind is the report they came in: Import or
export, Adding files, Organizing, Move list, Notice, Sync. A path that itself holds ": " splits
early; only the File and Folder columns show it, and the line stays whole. `line` is still what
⌘C copies and what Dismiss stores, so problems dismissed before stay dismissed. A click on a
header sorts by that column, as Finder compares names, rows the column holds the same keeping
their order, and a refresh keeps the sort and the selection. The sort isn't kept across
launches. The widths are kept in `state.json` as `problems.columns`, by column, applied the
first time the window shows, as the Downloads window keeps its own.

## Alternatives considered

- **Giving every report structured problems at its source**, the organizer's and the move
  list's among them. Rejected for now: those are strings made in Core and in the tag editor,
  which other phases are changing, and the split of "<path>: <detail>" gives the same columns
  for every line they make today.
- **An `NSAlert` whose text changes as it counts.** Rejected: its buttons are fixed once it
  shows, and it doesn't lay out again when the text grows.
- **Keeping the sheet up with an OK when nothing moves.** Rejected: it would be one more click
  for a result the status bar and the Problems window already give.
- **`NSTableView.autosaveTableColumns`.** Rejected: it keeps the widths in user defaults, a
  second place beside `state.json` for window state.

## Consequences

A large Organize Selected Files shows something within a frame of the command and can be
stopped while it reads. The Problems window can sit behind Finder. Its text for a stored file
issue reads differently from before in the columns, though the line copied is the same.
