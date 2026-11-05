# 0100. Get Info opens windows at once; writes queue; the temp file's identity after its close

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0020](0020-tag-writing.md), [0021](0021-tag-editor.md),
  [0077](0077-tag-editor-reads-at-once.md), [0081](0081-hung-share-off-the-main-thread.md)

## Context

The owner's feedback of 2026-11-05 (phase 42e): Get Info worked on one track at a time, a tag
change was slow to show, and Get Info was refused while a write ran. Writing a FLAC on the NAS
(an SMB share at `/Volumes/music`) failed with "something else replaced the temp file while the
tags were written".

What the code did: `TagEditing.open` refused while its sheet was open or a write ran, asked first
above 25 files (ADR 0081), read every file and only then showed a sheet on the main window.
After a write the app queued the edited folders with `LibraryWatcher.rescan(directories:)`,
which waits behind a running scan and, for a network folder with
`library.pausePollingDuringPlayback` on, until playback stops.

The writer took the temp file's identity (device, inode, size, mtime) with `fstat` while the
file was still open for writing, and before the rename compared it with an `lstat` by name. An
SMB server sets a written file's last write time when its handle closes ([MS-FSA] 2.1.5.4,
"Server Requests Closing an Open"; Samba also delays the update by up to 2 s after the first
write), so on the NAS the mtime moves after the `fstat`, and every write there failed the check.
APFS sets the mtime at each write, so the build Mac and the tests never saw it. The original's
own check didn't fire because the original is only read.

## Decision

**Get Info.** A window, not a sheet, opens at once on any selection, before a file is read,
showing the heading and "Reading tags…"; the fields fill in when the read ends. Several windows
can be open, each on its own selection, so nothing waits on another; Get Info on exactly the
tracks of an open window brings that window forward instead of opening a second copy, as Finder
does. ⌘I is enabled whenever tracks are selected. Closing a window that's still reading stops
its read between files, which is why the question before reading more than 25 files is gone:
nothing is held up by a large read any more, and closing the window ends it. Replace and Remove
Artwork act on the key info window, else the last opened.

**Writes.** Save writes one file at once; a batch asks in a sheet on its own info window, and
No leaves that window open with what was typed. Writes and undos go to one serial dispatch
queue, in the order asked, so Undo Tag Edit undoes the newest edit once those before it are
written. A window closes when its write is queued.

**After a write.** `LibraryWatcher.rescan(files:)` reads the written files at once on a queue of
its own, not behind a running scan and not waiting for playback, through
`LibraryScanner.rescan(files:)`: each file the index holds is read whatever its size and mtime
say and stored with the size and mtime a listing gives, so the next folder scan finds it
unchanged. A file the index doesn't hold is skipped, since only a folder scan knows whether its
folder's filter includes it. It sends `WatcherEvent.edited`, on which the browser refreshes its
rows and columns and the health report. The folders are still queued for a rescan after it, as a
backstop for a scan that read a file before the write and stores it after. Every open info
window showing a written file reads its files again, keeping what was typed and the art chosen.

**The temp file.** `writeTemp` closes the temp file first, then reads its identity by name,
after checking that the name still holds the file it wrote (the same device and inode, one
link). The check before the rename is the same as before: the name must hold that identity,
mtime included, with one link. A swap between the write and the close is refused with "something
else replaced the temp file", a change after the close with "something else changed the temp
file", and the second logs both identities, so the next report says which and why.

**Opens.** The editor reads each file through one open: the tags, the art and the fields holding
several values share the descriptor, and the last two the parse's reader. The writer reads the
original's tags, layout, replaced bytes and art through one open, and the temp file's tags,
layout and art through one, each parse with a reader of its own so one's step budget and
warnings don't reach the other. The whole-file hash, the copy and the read-back of the payload
stay.

## Alternatives considered

- **One info window whose contents a second Get Info replaces** — rejected: it loses what was
  typed in the first, and the owner asked to Get Info at any time; Finder and Swinsian open one
  window a selection.
- **Fill the fields from the index first, then from the files** — rejected: the index lacks
  fields (ADR 0021) and a value typed before the read ends would race it. The window shows at
  once; the fields follow in milliseconds locally and about 50 ms a file on the NAS.
- **Drop the mtime from the temp file's check** — rejected: it's what catches the temp file
  changed in place, the same inode, by someone who can write it. Taking it after the close keeps
  that check whole.
- **Write tags in place when they fit the padding** — not done: it would cut a write on the NAS
  from about four transfers of the file (hash, copy, write, read-back) to a few kilobytes, but a
  crash or a dropped share mid-write damages the original, which ADR 0020 refused, and the
  original can't be checked against the result before it's gone. Server-side copy on SMB
  (`FSCTL_SRV_COPYCHUNK`) would save the copy's transfer without that risk, but macOS gives no
  call for it this app can test without the NAS. Left for the owner to decide.
- **Hash the original while copying it** — not done: the copy reads the kept ranges in the new
  file's order, which for an MP4 that moves `moov` isn't the original's, and the clone path
  makes no copy at all. One pass saved on a whole-file write, for a second hashing path in the
  module that guards the files.

## Consequences

- Several writes can be queued; a quit while one runs leaves the original as it was, and at
  worst a temp file the next write to it removes (ADR 0020).
- Get Info on the whole library starts reading at once with no question; closing the window
  stops it.
- An edited track's row, columns, Now Playing and the open info windows show the new tags about
  as soon as the write ends, during playback too, on the NAS as locally.
- Bench (Apple Silicon, fixture files, median of 5): Get Info on one track shows its window in
  5 ms and its fields in 31 ms; on 100 tracks the fields in 43 ms; a FLAC title written and read
  back into the index in 12.7 ms (9.9 ms the write, 2.6 ms the rescan). The slow simulated NAS
  read of 200 files is 0.57 s, charged one open a file.
- The fix for the temp file can't be checked on SMB from the build Mac (ADR 0020); the owner's
  checkpoint writes a copy of a NAS file.
