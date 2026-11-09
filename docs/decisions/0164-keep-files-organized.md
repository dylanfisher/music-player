# 0164. Keep Files Organized renames edited files in the library folder to its layout

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0124](0124-drop-files-and-the-library-folder.md) (nothing renames a file
  already in the library), [0147](0147-moving-downloads-into-the-library.md) (Approve is the
  library folder's only renamer), [0020](0020-tag-writing.md) (the undo journal keys a file by
  its path)
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

Until now ADR 0124 said nothing renames, moves or retags a file already in the library, and
only Approve (ADR 0147) renamed files into the library folder.

## Decision

**The setting.** `library.keepFilesOrganized`, off by default, in the Library Folder box beside
Copy Added Files. The box's folder row is on while either checkbox is, since organizing needs
the folder but not the copy. It does nothing without a library folder.

**When files move.** After each tag write the user confirmed (Save in an info window, the
Discogs tagger's Apply) and after Undo Tag Edit, the files it changed that are inside the
library folder are renamed to the path `libraryFolderPath` gives their tags now. An undo is
included so a file whose edit is undone goes back to the name its old tags give; the user asked
for the undo as they asked for the edit. A write the app finishes at launch after a crash
(ADR 0107) is not organized: nobody confirmed it then. Staged downloads aren't in the library
folder, so their tag writes (ADR 0146) never move anything.

**Organize Selected Files…** (`track.organize`, in File > Moved and Removed Files) does the same
for the selected tracks whatever the setting. No tag edit covers it, so it first works out every
destination, off the main thread, and asks "Organize N Files?" with the number that will move
and the number left: already in place, outside the library folder, or with their path taken.
Organize is the confirmation. Asking renames nothing.

**How a file moves.** The same code as Approve: `renameNeverOver`, `renamex_np` with
`RENAME_EXCL`, and where a share refuses the flag an `lstat` and a plain `rename`. The fallback
now holds a lock in the app, since Approve and the organizer are two writers of the library
folder and could otherwise both find a name free. Destination parts that exist are named as
their folders list them (`listedPath`), so on a share that ignores case a change of case only is
no move. Rules:

- Only a file inside the library folder, its links followed, is moved. A file outside it is
  never touched; Organize Selected Files lists it.
- A destination folder must be inside the library folder, checked before and after its folders
  are made.
- A taken name skips the file, which stays where it is, and the Problems window lists it:
  "x.flac: not moved, …/01 Song.flac is already there". Two files of one batch with one path
  move the first. No numbered name, as ADR 0124 says.
- `EXDEV` skips the file and lists it. A rename never becomes a copy and a delete, as Approve
  refuses one between volumes.

**Tidying up.** A folder a move took a file from is removed with `rmdir` when that leaves it
empty, then its parent, and so on, never the library folder itself and never anything outside
it. `rmdir` refuses a folder with anything in it, so a folder with cover art, a `.cue`, a
`.DS_Store` or any other file stays. Nothing but music files moves: cover art and other files
stay in the old folder, which the Problems window lists ("…/Old Album: left in place, it holds
files that aren't audio") when no audio is left in it, for the user to tidy by hand. Moving
other files with the album would move files no tag edit was about, and an album folder can hold
files of two albums.

**Stats follow.** The moves go to `importMoves(lines:)`, the path an upgrade's old files take:
plays, history, rating, love, Date Added and playlist entries go to the new path under the same
path ID, and the move is logged for the other Macs. Then the changed files are rescanned at
their new paths, with the parse the write made. A scan between the rename and the move list can
match the move itself or leave the old path in Lost Stats; either way the move list finishes it.

**Undo follows.** The journal keys each file's record by its path. Right after the renames, on
the tag writes' own queue, so before any later write or undo can run, every record of a moved
path in every kept edit is pointed at the new path, so a file's edits still undo one after
another. The record whose edited size and mtime match the renamed file takes its identity
there: a rename changes neither, but a share may give the file a new inode. A record that can't
be updated is listed ("Undo Tag Edit can't find it at its new path"), and that edit then refuses
to undo the file, as any changed file is refused. A crash between the rename and the journal's
update leaves the same refusal, never a wrong write.

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

## Consequences

Files in the library folder can now be renamed by a tag edit. A tag edit of a file outside it
renames nothing. An info window left open on a moved file, other than the one saved, shows its
old path until it's opened again. The Discogs tagger's album keeps the paths it read; Analyze
reads them again.

## AGENTS.md

The music files bullet gets one clause after the Approve sentences: with Keep Files Organized
on, a tag edit or undo the user asked for, and Organize Selected Files after its confirmation,
rename files inside the library folder to its layout the same way, skipping a taken name and
removing only folders left empty (this ADR).
