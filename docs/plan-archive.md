

### 97. Rescanning the selected files

The owner (2026-11-22): "add ability to rescan only some files (the selected files)".

- [x] **97.1 Rescan Selected Files.** A command in the Library menu, the track table's context
      menu and ⌘K, enabled while the browser has tracks selected, that reads those files again
      through `LibraryWatcher.rescan(files:)`, whatever their size and mtime say, as after a
      tag edit. The status line says how many were read again, and a file that's gone or
      unreadable is reported as a scan problem as a folder scan reports it, not dropped. It
      reads the files only (AGENTS.md boundary). Tests: the command's enabled state, the
      paths it passes (an album row's tracks, not the row), and a missing file reported.

Implementation plan:

1. **Commands:** `CommandID.rescanSelected` ("Rescan Selected Files"), in the File menu after
   Rescan All (the library's commands are there; there's no Library menu) and in the track
   menu after Reveal in Finder; the palette lists it as it lists every menu command.
2. **Library:** `LibraryWatcher.rescan(files:parsed:done:)` hands its caller the summary, or
   the error it now only logs, besides sending `edited`.
3. **LibraryBrowser:** `rescanSelection(through:)` reads the selected paths, hands them over,
   and says "Read 12 files again" in the status bar, listing the files it couldn't read as
   their own report in the Problems window, as a folder scan's issues show.
4. **App:** the handler, on while the browser has tracks selected and a watcher runs.
5. ADR 0221; tests in `LibraryBrowserTests` (enabled state, the paths of a timeline's rows,
   a gone file reported) and `LibraryWatcherTests` (the reply).

Result (2026-11-22): `b37164dd..22e22d0a`, 4 commits. Rescan Selected Files (`track.rescan`)
is in the File menu after Rescan All, since the app has no Library menu, in the track
context menu and in ⌘K, on while tracks are selected and the library is watched. It reads
the files through `LibraryWatcher.rescan(files:parsed:done:)`, which now tells its caller what
it read; the activity line says "Reading N files again" until the latest rescan ends, the
status line then says how many were read and how many problems, and a gone or unreadable file
is listed in the Problems window, at most `ScanPipeline.maximumIssues` of them and then a
count. The folders are rescanned after, as for a tag edit, so with Remove Missing Tracks on a
gone file is reported and then dropped. Decided in ADR 0221. Cost: one Opus builder with one
fix round, 154k tokens, 62 + 16 tool calls, about 30 minutes; one Sonnet reviewer, 57k, and a
re-review, 60k. The review found an earlier rescan's end overwriting a later one's status, a
failed rescan leaving the last report, uncapped problems and a file listed twice; the
re-review found nothing. The full gate passed but for `theGlassHeadersAreFrosted` (no screen
recording here, fails on main too) and one HALOutput timing test, a different one each run
while phase 96 tested beside it at a load of 15 to 25.

