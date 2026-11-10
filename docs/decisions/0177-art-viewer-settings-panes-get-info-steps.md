# 0177. The art viewer opens laid out, Watched Folders apart again, and Get Info steps

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0172](0172-every-picture-and-bulk-covers.md) (the viewer showing before its
  decode), [0168](0168-a-library-pane-in-settings.md) (one Library pane, the Snapshots
  disclosure), [0160](0160-get-info-opens-as-it-stays.md) (an info window's files),
  [0021](0021-tag-editor.md) (the batch question)

## Context

The owner's third list of 2026-11-09, phase 70:

- **The art viewer moved after it opened.** It showed at once, drawing the hover's small image
  stretched over the screen, since the art it opens with is enlarged until the decode arrives.
  The decode is never enlarged past its pixels, so the art then shrank, and the pictures read,
  which comes after, added the strip of thumbnails and shrank it again.
- **⌘⌥⇧A for the art viewer.** It's already Show in All Music's (`track.showInAllMusic`, in
  the track menu and the View menu), so the owner's condition held: no chord is assigned.
- **Settings ▸ Library was too long**, with the watched folders list and its boxes over the
  library's own settings, and the snapshots were under a disclosure.
- **Get Info had no way to the next track**, and a title typed into a window on several
  tracks, meant for one of them, renamed them all after only the general batch question.

## Decision

- **The viewer shows at its final layout.** `ArtViewer.open` reads the file's pictures and
  decodes the art at the screen's pixels together, off the main thread, lays out the art and a
  strip button for each picture, and only then orders the window front. The thumbnails fill
  the buttons they already have. The pictures read lists them without their bytes, the same
  tag read the viewer made before, now ahead of the window instead of after it. A close while
  it opens, as the owner window closing, keeps it from showing. A failed decode still opens,
  on the hover's image; a failed read opens with no strip.
- **Settings ▸ Watched Folders is a pane again**, after Library in the toolbar, with the
  `folder` symbol: the folders list, Folder Changes and Network Folders. Library keeps Library
  Folder, Browsing and Database. Library Folder stays in Library: it's where Copy Added Files
  and Keep Files Organized put files, not how the watched folders are scanned. The class with
  the table is `FoldersPane` again. The palette's folder settings and Watched Folders… open
  it, and `--snapshot-of folders` draws it.
- **The snapshots always show**, a five-row list under Last Snapshot, with no disclosure.
- **Get Info steps through the list it was opened from.** The browser hands it a `TrackList`:
  the track table's ids when Get Info was chosen, the selected row, and a read of a row's path.
  ‹ and › sit at the left of the button row, on for a window on one track with a row that way;
  a window on several tracks, or one opened from the timeline, has them off. A step shows the
  track in the same window, read as a new window is. What was typed is dropped, as closing the
  window drops it: the window never asks on close, and a step that asked would be the only
  place that did. A row whose track has left the library says so on the window's line.
- **One title for several tracks asks.** A save whose edit sets a non-empty title on more than
  one file asks "Give all N tracks the title “…”?" in place of the batch question, so it's one
  question. Any other shared field asks as before, and so does clearing the titles.

## Alternatives considered

- **Drawing the opening image at the decoded art's frame**, to show at once without moving.
  Rejected: that needs the picture's pixel size, which means reading its bytes, and the decode
  after them is a few milliseconds more.
- **A count of pictures kept in the index**, for the strip's room. Rejected: the tag read is
  already cheap, and a new column would need every file read again.
- **A new window for each Get Info step.** Rejected: it would have to take over the kept frame
  of the window it replaces (ADR 0158), and it flickers.
- **Asking about unsaved edits on a step.** Rejected for now: closing doesn't ask either, and
  the owner asked for a step to handle them as closing does.
- **Reading the browser's list live on each step.** Rejected: a step after the table changed
  source would jump to an unrelated list.

## Consequences

The viewer appears after the tag read and the decode, a few milliseconds locally and more on a
NAS, instead of at once. Get Info's steps don't move the browser's selection. A list with the
same track twice steps by row, so both places are visited.
