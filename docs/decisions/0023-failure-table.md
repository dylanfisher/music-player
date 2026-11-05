# 0023. Every failure the app can meet, where it's caught, and how the user recovers

- **Date:** 2026-10-31
- **Status:** accepted
- **See also:** [0025](0025-threat-model.md) records the threats beside these failures: hostile files, links, SQL and the bundle.
- **Amends:** [0009](0009-scanning-and-watching.md), [0011](0011-playback-engine-and-hal-output.md),
  [0015](0015-config-file.md), [0022](0022-stable-track-identity-and-play-timeline.md)

## Context

Phase 14a asks that every failure the app can meet ends in a state the user is told about and
can recover from: never a crash, a hang or a silent loss. Earlier phases decided most of the
pieces one at a time: a volume that goes away removes nothing (0009), a lost DAC pauses and
offers to resume (0011), a broken config file shows in a banner and is never written over, and
a state file that doesn't decode is discarded whole (0015), a tag edit goes through a temp file
and a flushed journal (0020), and a stats rebuild leaves a notice (0022). This record collects
them in one table, from reading the code as it is, and decides the gaps the survey found.

## Decision

**The table.** Each row names the test that injects the failure and checks both what's reported
and that nothing else changed. Tests in `./scripts/check` are deterministic; the two scripts
cover what a test can't do quickly or hermetically.

| Failure | Detected | The user sees | Recovery | Test |
|---|---|---|---|---|
| NAS unmounted mid-scan | the root's `st_dev` changes, or a reader finds it gone | status bar problem: the folder went away; no track removed | next poll | `lostRootStopsReadingAndStoresNothing` |
| NAS mount dead mid-scan (listings and reads fail, mount stays) | each failed listing and read | unreadable folders and files in Problems; every earlier track kept | next poll reads them again | `aNASThatDropsMidScanKeepsEveryTrack` |
| NAS missing or empty at a scan | the root doesn't stat, or lists nothing while indexed | status bar problem; index kept | next poll | `missingFolderRemovesNothing`, `emptyMountPointRemovesNothing` |
| NAS drops mid-playback | the decoder's read fails, or its audio ends well before its length | Now Playing names the track that failed, and where its audio ended; the next one plays | play again once it's back | `aFileCutShortWhilePlayingIsReportedAndSkipped`, `aQueueOfBrokenFilesEndsInsteadOfLooping` |
| DAC unplugged while playing or before playing | the HAL's alive and device-list listeners | paused, "device lost"; then "device returned" | press Play | `losingTheDevicePausesAndItsReturnLetsPlaybackResume`, `playingWithTheDeviceUnpluggedReportsItLost` |
| DAC gone during a rate switch: stop, format, start | the step fails while the device reads as gone | as unplugged, resuming at the new track's start | press Play | `theDeviceGoingAwayAtEachStepOfARateSwitchIsReportedLost` |
| Disk full: database | `SQLITE_FULL`; the transaction rolls back | status bar: the scan or edit failed, with SQLite's reason | free space; a local folder rescans a minute later, then backs off to 15 minutes; a network one at its poll | `aFullDatabaseFailsTheScanAndKeepsTheIndex`, `aTransactionSQLiteRolledBackItselfThrowsWhatCausedIt`, `scripts/full-disk` |
| Disk full: state file | the atomic write fails | config banner: "couldn't save" | the change is kept and saved with the next one, or at quit | `aFailedSaveIsKeptAndSavedWithTheNext`, `scripts/full-disk` |
| Disk full: config file | the atomic write fails | config banner | retried after 1 s, doubling to 30 s | `aNewFileThatCouldntBeWrittenIsRetried`, `scripts/full-disk` |
| Disk full: tag journal | the record or bytes write fails | the tag editor lists the file and the ones not written | free space, save again | `aJournalThatCantBeWrittenStopsTheBatchAfterThatFile`, `scripts/full-disk` |
| Database locked by another process | `SQLITE_BUSY` after the 5 s busy timeout | at launch an alert, then quit; later, the status bar | close the other process; relaunch or wait for the next scan | `aLockedDatabaseFailsAfterTheTimeoutAndThenOpens`, `aLockedDatabaseAtLaunchFailsAndIsntMovedAside` |
| Database file SQLite can't read | `SQLITE_NOTADB` or `SQLITE_CORRUPT` while the window opens it at launch | an alert naming where the old file went, with Show in Finder, and a status bar notice | the next scan refills the index | `aLibraryFileThatIsntADatabaseIsMovedAsideAndReported`, `onlyTheNewestUnreadableFilesAreKeptEachUnderItsOwnName`, `twoLaunchOpensAtOnceMoveTheFileAsideOnce` |
| Config file corrupt or half-written | parse and validation, with lines | config banner; defaults in effect; the file is never written over | edit the file; it's read on save | `aBrokenFileAppliesNothingAndIsNeverWrittenOver`, `everyTruncatedConfigIsReportedAndNeverWrittenOver` |
| State file corrupt or half-written | decode | config banner: the file was reset | none needed; the next save writes it | `aStateFileThatDoesntMatchIsDiscardedAndReported` |
| Play state in the config of another shape ([0095](0095-play-state-across-quits.md)) | decode | log; the launch starts without it, the rest of the file applies | none needed; the next save writes it | `aPlayStateOfAnotherShapeReadsAsNothingAndBlocksNothing` |
| Play state's track not in this Mac's library | lookup in the index | log; nothing is loaded | play something | `aSavedTrackThisLibraryLacksStartsWithNothingLoaded` |
| Device restore record unreadable | decode | log; the record is deleted | none needed | `aRecordThatDoesntReadIsDiscardedAndReported` |
| Tag undo record corrupt | decode, or its bytes file doesn't match | the tag editor lists it as discarded | none; that edit can't be undone | `aRecordWithAnUnknownKeyAnywhereIsDiscardedAndReported` |
| Killed during a scan, tag write, playlist edit, state save or config save | relaunch | nothing: each write is a transaction or a temp file renamed over the old one | none needed | `scripts/kill-test`, `aCrashBeforeTheRenameLeavesTheOriginalAndTheNextWriteRecovers` |
| A command on timeline rows whose files are all missing | the selection resolves to no track | a beep and a status bar message | select a play whose file is there | `aSelectionOfOnlyMissingFilesFailsLoudly` |

**What this phase changes:**

- **A device error while the device is gone is a lost device.** A real DAC unplugged mid-switch
  fails the step it's in (stop, setting the format, start) before or after its listener fires.
  `DeviceOutput` used to report that as the new track failing, or the output failing, and the
  engine then skipped through the queue or stopped. Now a failed step waits up to 0.25 s for
  the provider to read the device as gone; if it does, it's abandoned and reported as
  `deviceLost` with the position to resume at, as an unplug at any other time is. If it reads as
  gone only later, the failure is reported as it was, and then as a loss when it does, so its
  return is still offered. `NullDevice` can go away during its next stop, configure or start,
  before the call fails or a set time after, to test each step and both orders.
- **A file whose audio ends early is a failed track.** A file cut short while it plays, or a
  partial one, read as a clean end: the track stopped early with nothing said. Decoding that
  stops more than half a second before the length in the header now reports the track as
  failed. The half second leaves room for encoders' rounding. AudioToolbox estimates an MP3's
  length from its size, so an MP3 is checked against the frame count its Xing/Info or VBRI
  header states, and one without such a header isn't checked.
- **A full database reports SQLITE_FULL.** SQLite rolls a transaction back itself on a full
  disk, and the explicit rollback that followed failed and hid the real error behind "no
  transaction is active". `Database.transaction` rolls back only a transaction still open.
- **A failed scan of a local folder is retried.** FSEvents reports a change once, so a scan that
  failed (a full disk, a locked database) used to lose those directories' changes until the
  next launch. The folder is now scanned whole a minute after a failed scan, the wait doubling
  with each failure in a row up to 15 minutes and starting over after a scan that finishes.
  Retries wait while a track starts, as polls do. A network folder still waits for its next
  poll. Only the first failure of a run shows in the status bar; its retries fail the same way.
- **A layout save that fails stays pending,** so the next save or the quit writes it, rather than
  losing the change once it's reported.
- **A library file SQLite can't read is moved aside, at launch only.** The alert used to quit
  the app at every launch, with no way to recover inside it. The window's first open at launch
  renames it, with its `-wal` and `-shm`, to `library.sqlite.unreadable-<time>-<id>`, makes a
  new library, and shows an alert naming the old file with Show in Finder; a discard notice in
  the new file names it too, so plays, ratings and playlists can be recovered by hand. Every
  other open (the scanner, the watcher, the reader, the command line) throws instead, since a
  connection opened before the move would go on writing the old file and split the library. A
  lock file beside the library keeps two launches at once from both moving it. The 3 newest
  moved files are kept and older ones deleted, so a file that keeps breaking can't fill the
  disk.
- **A discarded state file is reported** in the config banner, not only logged.
- **Timeline commands that would act on no track beep and say so.** Reading every selected
  play's track to disable the menu items costs a query per menu check, so the commands stay
  enabled and fail loudly instead.

**The tools.** `FailureDrill` (Tools) runs each operation against a `--home` folder until it's
killed, marking the start and end of each write, and reopens everything as the app does to
check it. `scripts/kill-test` sends seeded `SIGKILL`s across the operations, counts how many
landed during a write, and fails on any database that doesn't pass `PRAGMA integrity_check`,
any config or state file that doesn't decode or whose cut-short save is still beside it, and
any music file that differs from its pre-run hash once the tag journal is undone.
`scripts/full-disk` fills a disk image attached inside `~/Library/Caches/MusicPlayer`, never
`/Volumes`, under the database, the state file, the config file and the tag journal, the last
between two files of a batch. Neither runs in `./scripts/check`. The layout and config save
tests in `./scripts/check` fail the save with a folder that can't be written, since a disk
image isn't hermetic; `scripts/full-disk` covers the same saves with `ENOSPC`.

## Alternatives considered

- **Following the system default output when the DAC goes mid-switch** — rejected for the
  reason in 0011: it would play out of the speakers at the DAC's volume.
- **Disabling timeline commands when every selected play is missing** — rejected: it reads every
  selected play's track whenever a menu is checked.
- **`PRAGMA quick_check` at launch,** to catch corruption deeper than the header — rejected: it
  reads the whole database: 184 ms of the 1 s launch budget for the 43k fixture library on
  Apple Silicon, with the file already cached. Damage inside a table shows as a failed query
  where it's read.
- **Retrying a failed local scan at once** — rejected: a full disk would make it spin.
- **Deleting an unreadable library file** — rejected: its stats are the one thing a scan can't
  recreate.

## Consequences

The table is the list to extend when a phase adds a failure path; each new row needs a test.
A device that reads as connected for more than 0.25 s after a step fails is reported as an
output failure first; the hardware checkpoint on the ADI-2 shows how long the HAL takes. A
locked database at launch still quits after the alert, since the window can't open without
it; opening takes a write lock to check the schema. A kill mid-save can leave Foundation's
temp file (`state.json.sb-…`) beside the state or config file; the stores delete any at the
next start, and the kill harness fails on one still there after that. Files left outside the
watched folders when their removal at launch fails are only logged, and go at the next launch.
