# 0141. Rows dragged out of the app hand over their files, as a copy only

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0050](0050-remove-from-library.md) (the music-file boundary)
- **See also:** [0124](0124-drop-files-and-the-library-folder.md) (files dropped on the app)

## Context

The owner asked to drag tracks from the track table or the timeline to the Desktop, a Finder
window or another app, and get the files. Until now a drag of rows carried only track IDs, in
a type only this app reads, and offered no operation outside the app, so that Finder could
never copy or move a library file. A drag that carries file URLs lets the app that takes it
do what it likes with them, and Finder moves a file dragged to another folder on the same
volume unless the drag forbids it. The music files are written only by `TagWriter` and moved
only by Remove and Move to Trash (AGENTS.md), so a drag must not become a third way.

## Decision

**What a drag carries.** Each dragged row's pasteboard item holds the track ID as before and
its file's URL (`.fileURL`), from the path the row already has, so nothing stats the file. A
timeline row whose file left the index isn't dragged, as before.

**What it offers.** Inside the app the operations are unchanged: a move or a copy in the track
table (a playlist reorder, a drop on a playlist), a copy from the timeline. Outside the app
the drag offers `.copy` and nothing else, so Finder copies the file, to the Desktop or to a
folder on the same volume or on the NAS share, and never moves it or puts it in the Trash
(`KeyTableView.dragOperationMask`). The app writes nothing for a drag: the copy is the
receiving app's, from the original, which stays where it is.

**The app's own drops** take a drag from its own lists as tracks, by the IDs. The table and
the sidebar read the URLs only from a drag another app started (`draggingSource` is nil,
`SidebarController.fromAnotherApp`), so rows dropped on a playlist are added to it rather
than added to the library as files, and rows dropped anywhere else on the sidebar are
refused, as before. Before this, the sidebar took any drag holding audio file URLs as files
to add; once the app's own rows carried them, a drop on a playlist would have added the
tracks to the library again instead of to the playlist. The rule keys on where the drag
started rather than on the track-IDs type, since another app never writes that type and
the source is what AppKit reports for every drag.

**The boundary.** AGENTS.md's music-file line says a drag out offers a copy only and the app
writes nothing for it.

## Alternatives considered

- **File promises** (`NSFilePromiseProvider`), with the app writing the copy. Rejected: the
  app would be writing files outside the library at a place another app chose, a new writer
  beside `TagWriter` and ADR 0124's copy, when Finder's own copy reads the original only.
- **Offering every operation and trusting the receiver.** Rejected: Finder moves within a
  volume by default, and a drag to the Trash deletes, so a library file could leave the
  library without Remove's confirmation.
- **A modifier to allow a move**, as Finder's ⌘-drag. Rejected: moving a library file is
  Move to Trash's or a watched folder's business, and a mistaken drag can't be undone here.

## Consequences

Another app can read or copy any file a row names, as it can from Finder. A receiver that
ignores the offered operation could still move or delete the original; Finder and the usual
apps respect it. Playlist-file export is untouched. A drag of many rows writes a URL each,
from paths already in memory, so it costs no file system access.
