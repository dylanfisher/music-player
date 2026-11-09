# 0156. An upgrade sets aside the old files its new ones replace at their own paths

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0147](0147-moving-downloads-into-the-library.md) (Approve renames into the
  library folder never over a file, and deletes an upgrade's old files only after the new ones
  are checked in place)
- **See also:** [0124](0124-drop-files-and-the-library-folder.md) (the library folder's layout),
  [0026](0026-sync-identity-is-the-relative-path.md) (stats belong to a path)

## Context

The owner downloaded Random Access Memories as a new album, though a copy was already in the
library, and Approve refused it: "already in the library", for all 14 files. The download's tags
were the release's, so `libraryFolderPath` gave each file the path of the old copy's file.

That refusal is right for a new album, but the owner meant the download as an upgrade, and the
upgrade flow fails the same way. ADR 0147 moves the new files in first and deletes the old ones
only after the new ones are checked, so as not to delete anything before its replacement is in
place. When a new file's path is its old file's path, the old file is still there when the new
one moves in, and the move refuses it. An album upgraded with the release's tags and the
library's layout is exactly that case, so no such upgrade could be approved.

## Decision

**Set aside, then move in.** For an upgrade, an old file whose new file, paired through the
release's positions, goes to the old file's own path is renamed first, beside itself, to a hidden
name, `.upgrade-<job>-<n>`. Then the new file moves in as before. Scans skip hidden files, so the
index never has the set-aside file. After the new files are checked, the Trash takes each one
from its hidden name, as it takes the other old files. The rename stays in the old file's folder,
inside the library folder, and `LibraryFolderMove` checks that folder as it checks every
destination.

**Only the file being replaced.** The move may pass over a taken destination only when the file
there is an old file of this upgrade, paired with the new file going to its path. A new file that
would take the path of an old file of another track refuses the approval with the paths, since
that old file's stats would go to the wrong track. Any other file in the way refuses it as
before.

**Stats stay with the path.** Stats belong to a path (ADR 0026), so a file replaced at its own
path keeps its plays, rating, love and playlist entries without a move-list line. Only old files
at other paths are carried.

**In the ledger first.** The old files to delete and the hidden names are in the ledger before
the first rename (they were ledgered after the check before), so a run after a failure finds
them even when the sheet that resumes it no longer knows the job replaces an album. A failure
after a set-aside leaves the old file under its hidden name, and the failure names it. Retry
finishes from there.

**A new album that replaces one.** When the Approve sheet finds that a job queued as a new album
would take paths held by tracks of one library album, each carrying the job's release id, it
treats the job as an upgrade of that album. It lists that album's files, with the old files that
have no new one to tick, and says so in a line above the delete warning. Approve is still the
confirmation, as for an upgrade the owner queued. Paths taken by anything else refuse the
approval as before.

## Alternatives considered

- **Renaming the new file over the old one.** Rejected: the old file would be gone before the
  new one is checked, and on a share with a Trash it would skip the Trash.
- **Setting aside into the staging folder.** Rejected: the service deletes a job's staged folder
  on Reject, and the old files aren't the service's to delete.
- **`renamex_np` with `RENAME_SWAP`.** Not chosen: smbfs doesn't support it, so it would need the
  two-rename fallback anyway.
- **Asking which album to replace.** Not needed: the sheet already lists the files Approve
  deletes, and only an album of the same release counts.

## Consequences

An upgrade can now replace an album at its own paths, and a download queued as new can replace
the library's copy of its release. For the short time between the two renames, the old file's
path is empty. A scan in that time drops the file's row, but the stats stay with the path, and
the next scan reads the new file there. A failed run can leave hidden files in an album's folder
until Retry finishes it.

## AGENTS.md

The music files bullet's ADR 0147 sentence reads: Approve in the Downloads window renames the
staged files into the library folder, never over a file, and for an upgrade then passes the files
it replaces to the same Trash call, which on a share with no Trash deletes them; an old file
replaced at its own path is first renamed beside itself to a hidden name
(this ADR).
