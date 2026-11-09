# 0147. Approve moves a staged download into the library, and an upgrade deletes what it replaces

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0124](0124-drop-files-and-the-library-folder.md) (nothing moves a file into the
  library folder), [0050](0050-remove-from-library.md) and
  [0125](0125-trash-always-removes.md) (what passes files to the Trash, and what a share with
  no Trash does)
- **Amended by:** [0164](0164-keep-files-organized.md): Keep Files Organized renames files
  in the library folder through the same rename.
- **See also:** [0026](0026-sync-identity-is-the-relative-path.md) (the move list that
  carries stats),
  [0028](0028-network-folders-by-share.md) (paths by share),
  [0146](0146-staged-tag-writes.md) (the staged tag write before this)

## Context

Phase 54 stages Soulseek downloads in a folder on the NAS, `/Volumes/music/staging` on the
player Macs, on the same share as the library, and tags them there (ADR 0146). The owner asked
that "nothing should be imported into the real full music tracklist until manually reviewed and
approved", and chose that an approved album is moved from staging into the library, and that an
upgrade, a better copy of an album already in the library, sends the old files to the Trash and
keeps their stats. The owner's earlier request, "if the album is new from soulseek we can
automatically write the tags", covers the tags; this ADR covers the files.

AGENTS.md allows neither. ADR 0124 lets a drop create copies in the library folder and nothing
rename a file into it; ADR 0050 lets only Remove and Move to Trash pass files to the Trash, for
tracks the user picked. ADR 0125 found that a share with no Trash deletes the file and still
reports an error. The owner's NAS share has no Trash, so on it the upgrade's Trash call is a
permanent delete.

## Decision

**Approve is the confirmation.** It is enabled only for a staged job whose tag run was clean and
whose review claim this Mac holds. Its sheet shows the album, the release, the tags written, the
format found, and for an upgrade the files it replaces and how each maps to a new one. Nothing
moves before the owner confirms it. Once confirmed, the player tells the service `approved` and
`importing` and waits for its answer before the first rename; if the service refuses, or doesn't
answer, nothing moves.

**A new album.**

1. Each destination is worked out with `libraryFolderPath` (ADR 0124's layout) before anything
   moves. If any is taken, the whole approval is refused with the list; no album is half
   imported.
2. Staging and the library folder must be on one volume, or the approval is refused with that
   reason; a move between volumes would be a copy and a delete.
3. Each file is renamed with `renamex_np(RENAME_EXCL)`, which never replaces a file. Where the
   share refuses that flag (`ENOTSUP` or `EINVAL`), an `lstat` that finds nothing at the
   destination comes before a plain `rename(2)`. The app is the library folder's only writer and
   its import steps run one at a time, so nothing of its own can come between the two.
4. `LibraryFolderMove` takes sources only inside the staging folder and destinations only inside
   `library.folder`, both resolved with symbolic links followed; anything else is refused before
   any rename. Each file's step goes in a ledger, and every step can be worked out again from the
   file system, so a crash or another Mac resumes it.
5. The destination folders are rescanned (`rescan(directories:)`), as after a drop.

**An upgrade**, in this order, so nothing is deleted before its replacement is checked in place:

1. When the Approve sheet is built, before anything moves, the staged files are checked for a
   lossy origin with `analyzeFile(at:)` and `verdicts()` called directly, never `FileAnalyzer`
   or `MeasuresCache`, so no staged path enters the index. A `lossyOrigin` or `upsampled`
   verdict blocks Approve until the owner acknowledges it.
2. Old tracks map to new ones through the release's track index. An old track with no
   counterpart, or one with plays, a rating, a love or a playlist entry that would be lost,
   blocks Approve until the owner ticks it.
3. The new files move in as for a new album.
4. Each moved file is read again: its tags read, its size equals the one recorded after the tag write (ADR 0146), and the
   file count is the job's. A failure stops here, with the old files untouched.
5. The old files go to `moveToTrash`, the function Remove and Move to Trash calls, made public
   in `Features/LibraryBrowser` and handed to the import as a closure, so there is one copy. Only
   files the job lists as the album's, resolved by path and still carrying the release id, are
   passed.
6. Stats move from each old path to its new one through the move list (`importMoves`), which
   also logs the moves for the other Macs.

**The Trash on a share.** A file passed to the Trash counts as gone when it is no longer at its
path, as ADR 0125 says. On a share with no Trash, the owner's NAS among them, that is a permanent
delete. The Approve sheet says "permanently deleted if the share has no Trash". The delete comes
only after step 4's check, which is the guard for it. A file the Trash refuses stays where it
is; the job is failed at the delete step with the new files already in the library, and Retry
resumes from there.

**Resuming on another Mac.** The ledger is in each Mac's own index, so Resume Here finishes a
job another Mac left only if that Mac had moved nothing yet. A job moved in part is refused
there, with the reason that it can be resumed only on the Mac that started it: the moved files
took the tags their destinations came from, and the ledger that says which files those are is on
the first Mac. Neither Mac can half import an album, because the first run refuses the whole
album when a destination is taken, but a crash after some renames leaves a part-moved album in
the library until that Mac resumes it.

**Scans during a move.** The library watcher doesn't know an import is running. A scan that
starts between the first rename and the rescan the import ends with can read the files moved so
far, so a part of the album is in the tracklist for that time, and for an upgrade the old files
too. The window is short (the renames are on one volume, and for an upgrade the checks, the delete
and the carry), the import's own rescan reads the rest, and the index corrects itself on it. A
guard would need the ledger's share-relative paths mapped to mount points in every scan, which
the scan doesn't do; this is a known limit rather than something the player prevents.

**Reject** moves and deletes nothing in the player. The service deletes its staged folder, as
its own ADR says.

## Alternatives considered

- **Copying into the library and leaving the service to delete the staged copy.** Rejected: the
  share would hold two copies until the delete, and a rename on one share is a single step that
  either happens or doesn't.
- **A numbered name on a collision.** Rejected, as in ADR 0124: it adds a second track for one
  recording. The sheet lists what is in the way.
- **Deleting the old files first.** Rejected: a failed move would leave the album with no copy.
- **Moving replaced files to a holding folder on the share instead of the Trash.** Not chosen:
  the owner asked for the Trash. It would make an upgrade reversible on the NAS, and is the
  change to make if the owner's upgrade check (phase 54's owner checks) shows a problem.
- **Approving without a review claim.** Rejected: two Macs could import one album twice.

## Consequences

An upgrade on the NAS can't be undone from the app; the checks before the delete and the
sheet's wording are what stand in for the Trash. Approve works only where staging and the
library are on one volume. A crash at any step resumes from the ledger and the file system, on the Mac that started the move. The
staging folder never holds library files, and the library never holds a file Approve didn't
move.

## AGENTS.md

The music files bullet in Boundaries has one sentence for this ADR, after the ADR 0124 sentence:
Approve in the Downloads window renames the staged files into the library folder, never over a
file, and for an upgrade then passes the files it replaces to the same Trash call, which on a
share with no Trash deletes them. ADR 0146 adds the bullet's other clause. The detail stays here.
