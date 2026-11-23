# 0221. Rescanning the selected files

- **Date:** 2026-11-22
- **Status:** accepted
- **See also:** [0108](0108-faster-tag-writes.md) (reading edited files again),
  [0059](0059-problems-window-actions.md) (the Problems window)

## Context

The owner (2026-11-22) asked to rescan only the selected files. The only way to read a file
whose size and mtime haven't changed was Rescan All, which walks every watched folder, and on
the NAS that takes many minutes. The tag editor already reads the files it wrote again through
`LibraryWatcher.rescan(files:)`, at once and whatever their size and mtime say, but it only
logged a failure and dropped the issues of the files it couldn't read.

## Decision

- **Rescan Selected Files** (`track.rescan`) hands the selected tracks' paths to
  `LibraryWatcher.rescan(files:)`. A timeline row gives its track once, as other selection
  commands do. It's on while tracks are selected and a watcher runs.
- **Where it is:** in the File menu after Rescan All, since the app has no Library menu and the
  library's commands are there; in the track table's context menu after Reveal in Finder; in ⌘K
  as every menu command is. Not from links, as Rescan All isn't: a page could keep the NAS busy.
- **What it says:** "Reading 12 files again" in the activity line while it runs, then "Read 12
  files again" in the status bar, with the number of problems after a semicolon. While two
  run, the activity line and the result are the later one's; the report is the last to end. A file whose tags fail to read is stored with its
  failure and listed among the files with problems, as a folder scan stores it. A file gone
  from the disk, or one that can't be stat'ed, is a scan issue, listed in the Problems window as
  a folder scan's issue is, under its own report, which the next Rescan Selected Files replaces.
  It lists the first `ScanPipeline.maximumIssues`, as a folder scan does, and one row counts
  the rest, so a share gone under ⌘A over the library doesn't make a row per track. A file
  that's in its folder's issues too is listed once. A failure of the whole rescan, such as
  the database's, is shown in the status bar and empties the report, since the last one's
  rows would read as this one's.
- **The watcher's reply:** `rescan(files:parsed:done:)` gives its caller the summary or the
  error, besides sending `edited` as before; the tag editor passes nothing for `done`.
- **The folder rescan after stays:** `rescan(files:)` then rescans the files' directories, as
  for a tag edit. That finds the files it read unchanged, and removes a gone file from the
  index when `library.removesMissingTracks` is on, as any scan of its folder would.

## Alternatives considered

- **A new `WatcherEvent` for it.** Rejected: the browser would have to tell its own rescan
  from a tag edit's by the event, and every switch over the events would grow a case for one
  caller.
- **Skipping the folder rescan for it.** Rejected: it would need a second entry point for the
  same read, and the rescan of a few directories costs a listing each.
