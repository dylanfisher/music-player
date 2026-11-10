# 0164. Keep Files Organized renames edited files in the library folder to its layout

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0124](0124-drop-files-and-the-library-folder.md) (nothing renames a file
  already in the library), [0147](0147-moving-downloads-into-the-library.md) (Approve is the
  library folder's only renamer, and its fallback rename), [0020](0020-tag-writing.md) (the
  undo journal keys a file by its path)
- **Amended by:** [0175](0175-organize-progress-and-the-problems-table.md): Organize Selected
  Files' sheet opens before it counts, and the renames show their progress
- **See also:** [0026](0026-sync-identity-is-the-relative-path.md) (the move list that
  carries stats), [0154](0154-a-move-needs-more-than-a-length.md) (a scan's own move matching)

## Context

The owner asked on 2026-11-09: "Add a "Keep Files Organized" setting, limited to the library
folder. After each tag write you confirm, it renames the edited files to their
libraryFolderPath layout using renamex_np(RENAME_EXCL), the same way Approve does, and carries
stats and playlists over through the move list (importMoves/TrackMove). When the target name is
already taken, it skips the file and lists it in Problems. Pair it with an "Organize Selected
Files" command for existing tracks, and record the new move in an ADR and in the AGENTS.md
boundary."

Before this, ADR 0124 said nothing renames, moves or retags a file already in the library, and
only Approve (ADR 0147) renamed files into the library folder.

## Decision

**The setting.** `library.keepFilesOrganized`, off by default, in the Library Folder box beside
Copy Added Files. The box's folder row is on while either checkbox is, since organizing needs
the folder but not the copy. It does nothing without a library folder.

**When files move.** After each tag write the user confirmed (Save in an info window, the
Discogs tagger's Apply) and after Undo Tag Edit, the files it changed that are inside the
library folder are renamed to the path `libraryFolderPath` gives the tags they have after it. An
undo is included so a file whose edit is undone goes back to the name its old tags give; the
user asked for the undo as they asked for the edit. The files of such a write that are outside
the library folder are left out silently: the setting is limited to the folder, so they aren't
a problem. A write the app finishes at launch after a crash (ADR 0107) is not organized: nobody
confirmed it then. Staged downloads aren't in the library folder, so their tag writes
(ADR 0146) never move anything.

**Organize Selected Files…** (`track.organize`, in File > Moved and Removed Files) does the same
for the selected tracks whatever the setting. No tag edit covers it, so it first works out every
destination, off the main thread, and asks "Organize N Files?" with the number that will move
and the number left: already in place, outside the library folder, or with their path taken. A
track selected twice counts once. Organize is the confirmation, and it confirms that plan: the
tag writes' queue renames exactly its moves when it reaches them, each file read again first and
skipped and listed when it's gone or its tags give another place by then. Asking renames
nothing. The files outside the library folder are listed.

**How a file moves.** The same code as Approve: `renameNeverOver`, `renamex_np` with
`RENAME_EXCL`. Where a share refuses the flag, the destination name is reserved first with an
empty file made by `open(O_CREAT | O_EXCL)`, which an SMB server carries out as a create that
fails when the name exists, and the file is then renamed onto that empty file, which only this
call made. The library folder is shared: other Macs, and on one Mac both Approve and the
organizer, write it, so an `lstat` followed by a plain `rename`, which Approve used before,
could let two of them find a name free and the second rename replace the first file. A process
lock can't hold across Macs; the server's create can. A rename that fails removes the empty
file if it's still the one made (same inode, no bytes). A crash between the create and the
rename leaves the empty file, which every later move counts as a taken name and lists, for the
owner to delete; nothing deletes a file in the library folder it didn't just make. The same
is true when `fstat` on the new empty file fails, which on a share means the server stopped
answering: without the file's inode there is no way to tell, later, that what is at the name is
still that empty file and not one another Mac put there since, so it stays, the rename isn't
tried, and the failure is logged and listed for that file. While the name is reserved, a scan,
or the watcher reacting to the change, can briefly see the empty file, which reads as a file
with a problem until the rename lands and the next scan reads it again. Rules:

- Only a file inside the library folder, its links followed, is moved.
- A file whose destination is the same file, by device and inode, is in place, whatever
  spelling of the library folder led to it.
- A destination folder must be inside the library folder, checked before and after its folders
  are made. The folders made for a file whose rename then failed are removed while empty.
- A taken name skips the file, which stays where it is, and the Problems window lists it:
  "x.flac: not moved, already in the library: …/01 Song.flac". Two files of one batch with one
  path move the first. No numbered name, as ADR 0124 says.
- `EXDEV` skips the file and lists it. A rename never becomes a copy and a delete, as Approve
  refuses one between volumes.

**Case.** Destination parts that exist are named as their folders list them (`listedPath`), so
on a share that ignores case a change of case only is no move. A plan works out every
destination before any move, so a folder an earlier file of the same batch goes to keeps that
file's spelling, as the folder will once the earlier move makes it, and names are compared
folded on a volume that ignores case: two files tagged "Artist" and "ARTIST" go to one folder,
and the index stores the spelling the disk has.

**Tidying up.** A folder a move took a file from is removed with `rmdir` when that leaves it
empty, then its parent, and so on, never the library folder itself and never anything outside
it. `rmdir` refuses a folder with anything in it, so a folder with cover art, a `.cue`, a
`.DS_Store` or any other file stays. Nothing but music files moves: cover art and other files
stay in the old folder, which the Problems window lists ("…/Old Album: left in place, it holds
files that aren't audio") when no audio is left in it, for the user to tidy by hand. Moving
other files with the album would move files no tag edit was about, and an album folder can hold
files of two albums.

**Stats follow.** As Approve ledgers its steps, every move is recorded in the index, in a schema
part of its own (`layout_moves`), before the first rename, and the moves that didn't happen are
dropped after. The recorded moves go to `importMoves(lines:)`, the path an upgrade's old files
take: plays, history, rating, love, Date Added and playlist entries go to the new path under the
same path ID, and the move is logged for the other Macs. Then the changed files are rescanned at
their new paths, with the parse the write made. The carry runs after each organize and each time
the watcher starts, launch included, and takes every recorded move whose file is at its new path
and not its old one; a move whose file never left is dropped. A carry that throws keeps its
moves for the next one and names each in the Problems window; a carry that runs drops them all
and names each line the move list refused. A scan between the rename and the move list can
match the move itself or leave the old path in Lost Stats; either way the move list finishes it.

**Undo follows.** The journal keys each file's record by its path. Right after the renames, on
the tag writes' own queue, so before any later write or undo can run, every record of a moved
path in every kept edit is pointed at the new path, in one pass and one flush for the batch, so
a file's edits still undo one after another. The record whose edited size and mtime match the
renamed file takes its identity there: a rename changes neither, but a share may give the file a
new inode. An older edit's record keeps the old inode: it is compared only with the newer
record's original identity, taken before the move too, and undoing the newer edit hands it the
restored file's. A record that can't be updated is listed ("Undo Tag Edit can't find it at its
new path"), and that edit then refuses to undo the file, as any changed file is refused. A crash
between the rename and the journal's update leaves the same refusal, never a wrong write.

**With Approve.** An upgrade's Approve plans which old files it replaces and where the new ones
go (ADRs 0147, 0156). If the organizer renames one of those old files after the plan, by an edit
on this Mac or another, Approve finds the old path gone: the Trash gets only the files the job
lists that are still at their paths, so the renamed one stays in the library under its new
name, and the carry of its stats fails, since the organizer's carry took them from the old path
first, which the Downloads window shows as a failed carry step. The owner removes the duplicate
by hand. If Approve moves a file into a path
the organizer planned, the organizer's rename finds the name taken and lists the skip. Neither
replaces a file of the other; the worst case is a skip or a failed step, never a lost file.

## Alternatives considered

- **Moving cover art and other files with the album.** Rejected for now: those aren't music
  files, the edit wasn't about them, and the folder may hold another album's. Listing the folder
  shows what's left.
- **Deleting a folder holding only `.DS_Store`.** Rejected: the rule is never to delete a
  non-empty folder, and Finder makes one in most folders it opens.
- **Organizing only after edits, not undos.** Rejected: an undone edit would leave the file at
  the name of tags it no longer has.
- **Renaming in the scan instead.** Rejected: a scan reads files other apps changed, which nobody
  confirmed in this app.
- **A numbered name on a collision.** Rejected, as in ADR 0124.
- **A process lock around the fallback's check and rename.** Rejected: it doesn't reach another
  Mac. A hard link, which fails on an existing name, isn't offered by most SMB shares.

## Consequences

A tag edit can rename files in the library folder. A tag edit of a file outside it renames
nothing. An info window left open on a moved file, other than the one saved, shows its old path
until it's opened again. The Discogs tagger's album keeps the paths it read; Analyze reads them
again. A crash at the wrong moment can leave an empty file at a destination name, listed as
taken until the owner deletes it.

## AGENTS.md

The music files bullet gets one clause after the Approve sentences: Keep Files Organized, and
Organize Selected Files after its confirmation, rename files already in the library folder the
way Approve does (this ADR).
