# 0186. The tagger's tracklists in one scroll view, and a write's last steps in its line

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0164](0164-keep-files-organized.md) (Keep Files Organized after a write),
  [0175](0175-organize-progress-and-the-problems-table.md) (Organize's progress)

## Context

The owner asked, on 2026-11-10, for three things in the Discogs tagger (phase 74). Your Files
and Discogs Release, two tables of the same rows, scrolled together a frame apart: each was a
scroll view of its own, and the other followed its bounds notifications. AppKit draws a
responsive scroll before the main thread hears of it, so the follower is always behind. The
album list lost sight of the album selected when a release chosen in Other Releases… moved it
to another tab. And after the last tag of a big write, the tagger's line stayed on "4,254 of
4,254 written" while Keep Files Organized renamed the files, pointed Undo Tag Edit's records at
them and the library caught up, which the status bar showed and the tagger didn't.

## Decision

**Both tracklists sit in one scroll view** (`SideBySideTables`). Its document holds the two
tables side by side, each in a clip view of its own as tall as the document, so each fits its
columns to its half as a table in a scroll view does and never scrolls on its own. The two
headers sit in a row above the shared clip view that doesn't scroll, and the one scroller is
at the release's side. A table's scroll to a row, as the arrow keys make, and a drag's
autoscroll go to the shared document, since its own clip view shows it whole. Both tables
make a view for every row, which is fine for an album's tracklist.

**The album list keeps its place.** It scrolls to the album selected whenever that album's tab,
id or row differs from what the list last showed, and never otherwise, so a refresh, as a
write's progress makes 200 of, doesn't move a list the user scrolled. An album selected that
the tab doesn't list gives way to the tab's first, and a click below the rows doesn't empty
the selection.

**A write's line follows Keep Files Organized.** `TagEditing.write` tells its caller each
`OrganizeStep` of that write: the renames, from the same `OrganizeProgress` the status bar
gets, then the journal's follow, then the library's update. `written` gets a last argument the
app calls once its carry has asked for the rescan, and a write whose files moved tells its
caller it has ended only then. The tagger shows "Organizing files: N of M moved", "Updating
Undo Tag Edit for the moved files…" and "Updating the library…", for the oldest write in a
step while no write is on its tags. A step redraws once; the renames already report about each
1%, so the tag reports' throttle is unchanged.

## Alternatives considered

- **Two scroll views with responsive scrolling turned off.** The follower then moves in the
  same pass, but a clip view clamps the bounds it is given, so the two would still part while
  one rubber-bands at an end.
- **Headers floating inside the document.** NSScrollView's floating subviews would need
  content insets for the first row and the scroller; a row above the clip view is simpler.
- **Folding the steps into the tag progress's type.** `TagWriteProgress` is the tag writer's;
  the steps belong to the library and the app, so they come through a closure of their own.

## Consequences

- The carry's work runs on the write queue after any write queued before it starts, so with
  two Apply writes queued, the first can show "Updating the library…" until the second's tags
  and renames are done.
- A write with nothing to move, or with Keep Files Organized off, shows no steps and ends with
  its tags, as before.
