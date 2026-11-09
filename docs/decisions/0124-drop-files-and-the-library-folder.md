# 0124. Files dropped on the library window join the library, copied into a library folder if asked

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0009](0009-scanning-and-watching.md) (how files join the library),
  [0050](0050-remove-from-library.md) (the music-file boundary)
- **Amended by:** [0164](0164-keep-files-organized.md): Keep Files Organized renames files
  already in the library folder.

## Context

The owner asked to drag tracks from Finder into the library window and have them added, and
for an option that copies newly added tracks into one library folder, laid out by artist and
album, as Swinsian's library folder does. Until now a file joined the library only by being in
a watched folder when it was scanned, and AGENTS.md let only `TagWriter` write music files and
only Remove and Move to Trash move them. Copying creates files in a folder the app scans, so it
needs a line of its own in that boundary. The owner settled the behavior on 2026-11-06.

## Decision

**The drop.** Audio files and folders dropped from another app on the track table or the
sidebar are added (`LibraryBrowser.addFiles`). The pasteboard's URLs are filtered on the main
thread by extension, and a folder by the slash Finder ends its URL with, so nothing there reads
the volume; files that aren't audio are left out, as a scan leaves them out. A playlist file
dropped on the sidebar is still imported. `planAdding` then stats each path, and lists dropped
folders that will be copied, in a detached task (`blockingFileWork`).

**Copy Added Files off** (the default, `library.copyAddedFiles`): a file or folder inside a
watched folder (where the index last found it, as Locate… checks) has its directory rescanned
through `rescan(directories:)`. Anything else makes its folder watched: a file its parent
folder, a folder itself. Before any folder becomes watched, a sheet over the window lists them
all ("Watch “x”?" or "Watch N New Folders?") with Add and Cancel; Cancel adds nothing from the
drop, including what would only have been rescanned. Add passes each folder to the path Add
Watched Folder… uses (`AppDelegate.watch`), so a share is stored by share as ADR 0028 says, and
the watcher's restart scans it. A folder inside another one listed, or listed twice, is left
out.

**Copy Added Files on**, with `library.folder` set: files outside the library folder, dropped
or in a dropped folder, are copied into it; files already in it aren't copied, and their
directories are rescanned or watched as above. If no watched folder holds the library folder,
the sheet lists it and Add makes it watched, after the copies, so its first scan reads them.
Otherwise the directories the copies went to are rescanned, since FSEvents doesn't see a share.
The status bar shows "Copying into the library folder: 3 of 20" with its bar, then "Copied 19 of
20 files into the library folder"; each file not copied is a line in the Problems window, which
opens. With the setting on and no folder set, or the folder not an absolute path, or not there
(an unmounted share), the drop adds nothing and the status bar says why.

**The layout** (`libraryFolderPath`): `<album artist, else artist>/<album>/<NN title>.<ext>`,
the track number in two digits, after `<disc>-` when the disc number is above 1 or the disc
total is (`1-03 Title.flac`). A file with no track number is named by its title, one with no
title by its own file name. A missing artist or album is `Unknown Artist` or `Unknown Album`.
The extension is the source's. Each name is precomposed, loses `/ : \ * ? " < > |` to `_` and
control characters, and loses leading and trailing dots and spaces: a leading dot would hide
the file from the scanner, and SMB servers drop or refuse trailing ones. A name is cut at a
whole character to 255 bytes of UTF-8, the extension kept.

**Collisions never overwrite.** The copy is opened with `O_CREAT | O_EXCL`, so a file already
at its path, or one another copy of the same drop put there first, makes the open fail. That
file is not copied and is listed: "x.flac: not copied, …/03 Song.flac is already there". Most
collisions are the same file dropped twice, and a numbered name such as `03 Song 2.flac` would
add a second track for one recording.

**The copy reads the original only.** The bytes, extended attributes and permissions go with
`fcopyfile`, then the copy is closed and its close checked, since an SMB write can fail there.
A copy that fails partway is removed; it was made by this call, which is the only file this
removes. The library folder's subfolders are created as needed.

**Settings.** Both settings are in a Library Folder box on the Watched Folders pane, the
checkbox first; it turns the folder's row on, as the receiver's checkbox does its rows. The
folder row shows the path with Choose… (Change… once set) and Clear. The path is stored as
chosen, not by share. Copy Added Files is a toggle in the Library menu and ⌘K too, as every
checkbox setting is.

**The boundary.** AGENTS.md now names the copy: it creates files in the library folder,
reads the originals, and removes only a copy of its own that failed. Nothing renames, moves or
retags a file already in the library, at the drop or at a tag edit. Tests copy generated
fixtures between temporary folders.

## Alternatives considered

- **Moving instead of copying.** Rejected: a move deletes the original, so a drop from a
  camera card, a download or another app's library would take the file away from where the
  user had it. A copy that goes wrong leaves the original as it was.
- **A numbered name on a collision**, as Finder makes. Rejected for the duplicate it makes of a
  file dropped twice; the listed line says where the file already is.
- **Copying to a hidden temporary name and renaming.** Rejected: `rename` replaces a file at
  the target, `renamex_np`'s `RENAME_EXCL` isn't known to work on the owner's SMB share, and a
  scan that reads a copy still being written records it once and reads it again at the rescan
  after the copy.
- **Storing the library folder by share**, as watched folders are. Rejected for now: the
  folder is one path on one Mac. A share mounted at another point makes the drop say the folder
  isn't there, and Change… fixes it.
- **Watching the parent of a dropped folder** rather than the folder. Rejected: the user
  dropped that folder, and its parent may hold much more.
- **Asking before each folder.** Rejected: one sheet listing every folder answers the drop at
  once.

## Consequences

A file dropped from a folder like Downloads makes the whole of Downloads watched once the user
agrees. A dropped file in a watched folder whose filter excludes it, or that was removed from
the library (ADR 0050), stays out after the rescan. A new watched folder that holds an older
one is added as any folder from Add Watched Folder… is. Tracks that share an album, disc,
number and title but differ (two versions with the same name) collide, and the second is
listed rather than copied.
