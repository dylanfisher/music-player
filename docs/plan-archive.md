

### 60. Keep Files Organized

Asked by the owner on 2026-11-09, with the boundary change: "record the new move in an ADR and
in the AGENTS.md boundary".

- [x] **Setting:** Keep Files Organized, limited to the library folder. After each tag write
      the user confirms, the edited files are renamed to their `libraryFolderPath` layout with
      `renamex_np(RENAME_EXCL)`, as Approve does, and stats and playlists carry over through
      the move list (`importMoves`/`TrackMove`). A taken target name skips the file and lists
      it in Problems.
- [x] **Organize Selected Files:** the same for selected tracks already in the library folder.
- [x] **ADR and AGENTS.md boundary** for the new move.

Implementation plan, phase 60 (ADR 0164):

What exists, found by search (map.md recipes): the layout is `libraryFolderPath` in
`Core/Library/LibraryFolderLayout.swift`; Approve's renames are `LibraryFolderMove`, over
`MoveCalls`; the move list is `LibraryIndex.importMoves(_:)`, reached through
`LibraryWatcher.importMoves(lines:)`. Tag writes and undos run one at a time on `TagEditing`'s
write queue and report through `written`; the undo journal (`TagUndoJournal`) keys each file's
record by its path, with the edited file's size, mtime and inode. Problems rows come from
`LibraryStatus`'s reports, filled by `LibraryBrowser.finish`.

- 60.1 Shared rename (refactor): `LibraryFolderMove`'s exclusive rename (`renameNeverOver`),
  its case-preserving path (`listedPath`) and its library check (`isFolder`) become
  file-level functions, which Approve and the organizer both call; `layoutDestination` reads
  the tags and gives the destination for the copy, Approve and the organizer.
- 60.2 The organizer (`Core/Library/LibraryFolderOrganize.swift`): `layoutMoves` plans,
  `moveToLayout` renames a plan. A file outside the library folder (links followed) is
  skipped; one already in place is left; one whose path is taken, or on another volume
  (`EXDEV`), is skipped and listed, never copied. Folders a move leaves empty are removed with
  `rmdir`, up to but never the library folder itself; a folder still holding other files
  (cover art) stays, and is listed when no audio is left in it.
- 60.3 The journal follows (`TagWriter.follow(_:)`, `TagUndoJournal`): every record of a
  moved path takes the new path, and the one whose edited size and mtime match the file takes
  its identity there, since an SMB rename may renumber the inode. Undo Tag Edit then finds it.
- 60.4 Setting `library.keepFilesOrganized` (`AppSettings`), in the Library Folder box; the
  box's folder row is on while either checkbox is (`switchKeys`).
- 60.5 `TagEditing` hook: with a folder from `organizingFolder`, each write or undo the user
  asked for is followed on the write queue by the organizer and the journal's follow, so no
  later write or undo comes between; `written` gets the report at the new paths and what was
  organized. Recovery at launch isn't organized.
- 60.6 Organize Selected Files… (`track.organize`, in File > Moved and Removed Files):
  `LibraryBrowser.organizeSelection` plans off the main thread, asks "Organize N Files?" with
  the count that will move and the skipped, then hands the plan to `TagEditing.organize`.
  `finishOrganizing` says what moved in the status bar and lists the rest in Problems.
- 60.7 App wiring: the moves are recorded in the index before the renames
  (`LayoutMoveLedger.swift`) and `carryLayoutMoves` gives them to `importMoves(lines:)`, so
  stats, ratings and playlists follow, after each organize and each watcher start; the new
  paths are rescanned.
- 60.8 ADR 0164, the AGENTS.md clause, ADR 0124's and 0147's amended-by lines, and the
  "Later" item's organize part reworded as done.

Tests: a taken name skipped, a move to another album folder, a file outside the library
folder, `ENOTSUP` and `EXDEV` through `MoveCalls`, another client taking a name during the
fallback, empty-folder cleanup and a folder with art kept, one spelling per folder on a volume
that ignores case, stats and a playlist entry carried through `importMoves` and after a failed
carry, undo after a move, and the hook's ordering in `TagEditorTests`. All in temporary
folders.

- [x] **Owner check, on a scratch folder on the share:** with two Macs, organize on one and
      Approve or organize on the other into the same names: neither file is replaced, and the
      second is listed as taken. Look in the log for "reserving the name" to see the share
      took the fallback, and that no empty file is left after a refused rename.

Result, phase 60: shipped all three items (ADR 0164; 0020, 0124 and 0147 amended; the AGENTS.md
boundary). With Keep Files Organized on, a confirmed tag write or undo renames its files inside
the library folder to their layout, and Organize Selected Files does it after a confirmation that
names the count, running exactly the plan it confirmed. A taken name, a file outside the folder,
or a move across volumes is skipped and listed; only folders a move empties are removed. Where a
share refuses `RENAME_EXCL`, the name is reserved with `open(O_CREAT|O_EXCL)` before the rename,
which holds across Macs; Approve shares that helper. Moves are written to a `layout_moves`
ledger before the first rename and carried on the write queue, at each organize and at every
watcher start. The undo journal follows a batch of renames in one pass. Gate: one file-safety
and one simplify review, then a re-review of the fixes; 8 correctness findings, all real, fixed
with tests, 4 simplifications, then 2 more from the re-review (the ledger carry raced an
organize; a placeholder whose fstat failed stays, as recorded). No data-loss path found.
`theGlassHeadersAreFrosted` fails as in every agent session. Cost: implementer about 440k tokens
plus the last fixes, 449 tool calls, 92 min; reviewers 206k tokens, 25 calls, 4 min.

Owner steps, on a scratch copy first: set the library folder to a scratch copy with one album
folder holding cover.jpg, turn on Keep Files Organized, change a track's album in Get Info, and
check the move, its plays, rating and playlists, and the old folder gone or listed; Undo Tag
Edit puts it back; a taken name overwrites nothing and is listed; Organize Selected Files… over
tracks in and outside the folder, its count, and Cancel; then on a scratch folder on the share,
the same, the log's `RENAME_EXCL` fallback line, and undo after a moved file; two Macs organizing
into the same scratch folder at once; on a second Mac, the moves and stats through sync.


