# 0136. Asking before a rescan, and undoing a tagger write

- **Date:** 2026-11-08
- **Status:** accepted
- **See also:** [0022](0022-stable-track-identity-and-play-timeline.md) (the stats rebuild's discard notice),
  [0107](0107-tags-written-in-place-within-the-padding.md) (writes in place), [0133](0133-one-confirmation-for-a-match-set.md)
  (the tagger writes through Undo Tag Edit's queue), [0131](0131-discogs-matching.md) (the tiers)

## Context

The owner's testing after 51g, on 2026-11-08 (51h):

- The first launch after 51f rescanned the whole library with no word: a new build's index
  schema rebuilt the index part, and every file was read again. It looked like a corrupted
  library (51.32).
- Undo Tag Edit after the tagger wrote 22 MP3s on the NAS failed for all of them: "can't copy
  its extended attributes: Permission denied", from `fcopyfile(COPYFILE_ACL | COPYFILE_XATTR)`
  in `FileReplace.copyAttributes`, though the tagger's write of the same files went through
  (51.39).
- Undo Tag Edit undoes the newest edit anywhere, so pressed in the main window it can put back
  a tagger batch the owner didn't mean (51.39).

## Decision

### The rescan question

- **When it asks:** before a rebuild drops a part a rescan refills, in a library that already
  holds that part. `LibraryIndex.init(at:movingAsideIfUnreadable:confirmRescan:)` takes the
  question; only the window's first open at launch passes it, as an alert with Rescan Now and
  Quit. Nil asks nothing, so the `scan` command, the readers and the tests are as before. A new
  library never asks.
- **Quit leaves the file as it was:** the parts to rebuild are worked out read only, and the
  question comes before the first statement that changes the file. A declined rescan throws
  `LibraryError.rescanDeclined`, the app terminates without the error alert, and the next
  launch asks again.
- **The why is per part, not per build:** `SchemaPart.rescanWhy` says what the part holds. The
  stored SQL is a part's only identity, so a build can't say what it changed, only that the
  part's tables did. `RescanNotice` builds the text from any list of parts plus "Every file is
  read again. Plays, ratings and playlists stay.", so a later part that needs a rescan adds its
  own line and nothing else.
- **Stats rebuilds don't ask:** there "plays stay" would be false. They keep the discard notice
  of ADR 0022.
- **The status bar** says "Rebuilding the index: Music: 300 of 1,200 read" in place of
  "Scanning" for each folder until one of its scans ends. The flag that the index rebuilt is in
  memory, so a quit in the middle of the rescan reads as a plain scan at the next launch.

### Copying a file's attributes one at a time

- **The cause:** a tag that fits the padding is written in place (ADR 0107), with no temp file
  and no attribute copy. Undo always goes through a temp file, so the undo of those 22 files was
  the first `fcopyfile` on them. `fcopyfile` sets every extended attribute and the ACL in one
  call, and one refusal fails it with no name. Which attribute the SMB server refuses hasn't
  been read off the NAS yet; `com.apple.provenance`, which macOS 13 and later manage
  themselves, is the first suspect.
- **The copy:** the ACL still through `fcopyfile(COPYFILE_ACL)`, then each extended attribute
  through `fgetxattr` and `fsetxattr`, so a failure names what failed: "can't copy the extended
  attribute com.apple.provenance: Permission denied", or "can't copy its ACL". The temp path of
  a forward write uses the same function.
- **The skip list:** `unsettableAttributes` in `FileReplace.swift`, the attributes macOS manages
  itself, today only `com.apple.provenance`. A refusal (`EACCES`, `EPERM`, `ENOTSUP`) of one of
  them leaves it off the new file and is logged at notice level with the file and the name. Any
  other refusal still fails the write: a Finder tag or an attribute of the owner's is never
  dropped quietly. An ACL refusal isn't skipped. The list grows only from what the owner's
  `xattr -l` and `ls -le@` of one of the NAS files show.
- **The fault** `WriteFaults.refusingAttribute` stands in for the server, by attribute name and
  "acl". Tests add a name of their own to `WriteFaults.unsettable`, since no process can give a
  file a `com.apple.provenance` attribute or take one away.

### Asking before undoing another window's edit

- **The origin:** the journal keeps the window an edit was made in, as an `origin` file in the
  edit's folder (`TagEditOrigin`: `tagEditor` or `discogsTagger`), written with the folder.
  `TagWriter.newestEdit()` reads the newest edit's origin and file count without changing
  anything. An edit with no origin file is unknown and asks nothing: stored data has one shape,
  and there is no migration.
- **The rule:** Undo Tag Edit, after the writes queued before it, asks "Undo the Discogs
  tagger's edit of 22 files?" when the newest edit's origin is known and isn't the kind of
  window it's pressed in: the tagger's window when that's the key window, the tag editor's for
  any other. Cancel leaves the edit undoable.

## Alternatives considered

- **Undoing an in-place write in place,** which would skip the temp file and the attribute copy.
  Rejected: it needs the in-place journal (its marker and torn-write recovery, ADR 0107) run
  backwards, a larger change than the copy.
- **Skipping every refused attribute.** Rejected: a refused Finder tag or attribute of the
  owner's would go without a word, against failing loudly.
- **A persisted rebuild flag,** so the status bar says "Rebuilding" after a quit mid-rescan.
  Rejected: a part of its own for one word.
- **Asking for stats rebuilds too.** Rejected: the question promises plays stay, and the
  discard notice already says what went.
- **A why per build,** written by the build that changed the part. Rejected: nothing stores a
  build's identity beside the SQL, and the next part that needs a rescan would need its own.

## Consequences

A build that changes the index asks once, and the owner can quit and come back to it. Every
attribute refusal now names its attribute, and the one macOS manages itself no longer stops an
undo on the NAS; any other refused attribute still does, with its name, until the owner's
listing says whether it belongs on the list. An undo that crosses windows asks first.
