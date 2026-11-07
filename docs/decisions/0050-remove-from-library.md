# 0050. Remove tracks from the library, or move their files to the Trash

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0020](0020-tag-writing.md), [0034](0034-folders-and-library-health.md)
- **Amended by:** [0059](0059-problems-window-actions.md): the Problems window restores a
  Removed row, and removes a Lost Stats one from the library.
  [0124](0124-drop-files-and-the-library-folder.md): a drop copies files into the library
  folder.
  [0125](0125-trash-always-removes.md): the files the Trash refused are removed from the
  library, and a file moved is one gone from its path.

## Context

Row 25.3 asks for Remove… on the selected tracks, as Swinsian has it: take them out of the
library, or out of the library and into the Trash. Until now the index held every audio file in
the watched folders, and the only way to drop one was to move it out. The owner answered on
2026-11-02: allow the Trash, and keep removed tracks excluded so a rescan doesn't add them back.

Moving a file to the Trash moves a music file, which AGENTS.md allowed only `TagWriter` to do.

## Decision

- **Remove…** (`track.remove`) acts on the selected tracks of the track table or the timeline,
  and only while that list has the keys. Unlike Reveal in Finder, it is off with the keys in the
  sidebar or a pane, so ⌫ there doesn't ask about tracks the user isn't looking at. Its chord is ⌫, which can't be a menu key equivalent, since text
  fields type it, so it reaches the command from the focused list, as Space does; the queue
  takes its own ⌫ first, to remove from the queue. It asks "Remove Track?" or "Remove N Tracks?"
  as a sheet with Remove from Library, Remove and Move to Trash, and Cancel, which is the default
  button, so Return or Escape changes nothing.
- **Remove from Library** deletes the tracks' rows from the index and adds their paths to the
  `removed` table, keyed by path ID
  ([0022](0022-stable-track-identity-and-play-timeline.md)). It is its own schema part, so its
  shape can change without discarding the stats. A scan skips a path in the table before
  reading it. The paths keep their plays, ratings and playlist entries, and neither move
  matching nor Lost Stats offers them, since they didn't leave. A playlist entry of a removed
  track counts under Lost Entries, like any entry without a track. The table is this machine's:
  the sync log carries stats, not what each machine indexes ([0038](0038-sync-logs.md)).
- **Remove and Move to Trash** calls `NSWorkspace.recycle` with the paths read when the sheet
  was confirmed, and nothing else. The files it moved leave the index and are dismissed from
  Lost Stats, so their stats wait without being offered to another track. They aren't
  excluded: a file put back from the Trash is read by the next scan of its folder and gets its
  stats back. A file the Trash refused stays in the library, and the status bar says why.
- **The boundary.** AGENTS.md now names this call as the one other way a music file moves.
  Nothing else in the app moves, renames or deletes a music file, and no test calls the real
  Trash: the browser takes the call as a closure, which tests replace.
- **Library Health** gets a *Removed* check listing each removed path as a line, so it shows in
  the sidebar's count and the Problems window. **Restore Removed Tracks…**
  (`library.restoreRemoved`) opens a sheet with a menu of the removed paths and Restore, Restore
  All and Cancel. Restoring deletes the paths' rows and rescans their folders, which reads the
  files back with their stats. The check itself offers no Restore: as with Lost Stats, the
  command is in the File menu and ⌘K, short of row 25.3's "can restore them" from Library
  Health. Actions on the report's rows are row 26.1's.

## Alternatives considered

- **Excluding trashed files too.** Rejected: a file put back from the Trash would stay out of
  the library until restored by hand, though the user undid the delete.
- **Keying the exclusions by path text.** Rejected: a share mounted at a new point rewrites the
  paths' rows ([0028](0028-network-folders-by-share.md)), and an exclusion keyed by ID moves
  with them.
- **Checking the exclusions in `store` instead of the walk.** Rejected: the scanner would still
  read every excluded file on each change, over the NAS. A file changed while a scan that began
  before its removal runs can come back; removing it again excludes it.
- **Restoring from a list of checkboxes.** Rejected for now: a menu of paths and Restore All
  match the Lost Stats sheet ([0034](0034-folders-and-library-health.md)) and need no new view.
