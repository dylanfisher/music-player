# 0023. Every failure the app can meet, where it's caught, and how the user recovers

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0009](0009-scanning-and-watching.md), [0011](0011-playback-engine-and-hal-output.md),
  [0015](0015-config-file.md)

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
| NAS drops mid-playback | the decoder's read fails | Now Playing names the track that failed; the next one plays | play again once it's back | `aFileCutShortWhilePlayingIsReportedAndSkipped`, `aQueueOfBrokenFilesEndsInsteadOfLooping` |
| DAC unplugged while playing or before playing | the HAL's alive and device-list listeners | paused, "device lost"; then "device returned" | press Play | `losingTheDevicePausesAndItsReturnLetsPlaybackResume`, `playingWithTheDeviceUnpluggedReportsItLost` |
| DAC gone during a rate switch: stop, format, start | the step fails while the device reads as gone | as unplugged, resuming at the new track's start | press Play | `theDeviceGoingAwayAtEachStepOfARateSwitchIsReportedLost` |
| Disk full: database | `SQLITE_FULL`; the transaction rolls back | status bar: the scan or edit failed, with SQLite's reason | free space; a local folder rescans a minute later, a network one at its poll | `aFullDatabaseFailsTheScanAndKeepsTheIndex`, `aFullDatabaseRollsBackEveryEdit`, `scripts/full-disk` |
| Disk full: state file | the atomic write fails | config banner: "couldn't save" | the change is kept and saved with the next one, or at quit | `aFailedSaveIsKeptAndSavedWithTheNext`, `scripts/full-disk` |
| Disk full: config file | the atomic write fails | config banner | retried after 1 s, doubling to 30 s | `aNewFileThatCouldntBeWrittenIsRetried`, `scripts/full-disk` |
| Disk full: tag journal | the record or bytes write fails | the tag editor lists the file and the ones not written | free space, save again | `aJournalThatCantBeWrittenStopsTheBatchAfterThatFile`, `scripts/full-disk` |
| Database locked by another process | `SQLITE_BUSY` after the 5 s busy timeout | at launch an alert, then quit; later, the status bar | close the other process; relaunch or wait for the next scan | `aLockedDatabaseFailsAfterTheTimeoutAndThenOpens` |
| Database file SQLite can't read | `SQLITE_NOTADB` or `SQLITE_CORRUPT` while opening | status bar notice naming where the old file went | the next scan refills the index | `aLibraryFileThatIsntADatabaseIsMovedAsideAndReported` |
| Config file corrupt or half-written | parse and validation, with lines | config banner; defaults in effect; the file is never written over | edit the file; it's read on save | `aBrokenFileAppliesNothingAndIsNeverWrittenOver`, `everyTruncatedConfigIsReportedAndNeverWrittenOver` |
| State file corrupt or half-written | decode | config banner: the file was reset | none needed; the next save writes it | `aStateFileThatDoesntMatchIsDiscardedAndReported` |
| Device restore record unreadable | decode | log; the record is deleted | none needed | `aRecordThatDoesntReadIsDiscardedAndReported` |
| Tag undo record corrupt | decode, or its bytes file doesn't match | the tag editor lists it as discarded | none; that edit can't be undone | `aRecordWithAnUnknownKeyAnywhereIsDiscardedAndReported` |
| Killed during a scan, tag write, playlist edit or state save | relaunch | nothing: each write is a transaction or a temp file renamed over the old one | none needed | `scripts/kill-test`, `aCrashBeforeTheRenameLeavesTheOriginalAndTheNextWriteRecovers` |
| A command on timeline rows whose files are all missing | the selection resolves to no track | a beep and a status bar message | select a play whose file is there | `aSelectionOfOnlyMissingFilesFailsLoudly` |

**What this phase changes:**

- **A device error while the device is gone is a lost device.** A real DAC unplugged mid-switch
  fails the step it's in (stop, setting the format, start) before or after its listener fires.
  `DeviceOutput` used to report that as the new track failing, or the output failing, and the
  engine then skipped through the queue or stopped. Now a failed step first asks the provider
  whether the device is there; if not, it's abandoned and reported as `deviceLost` with the
  position to resume at, as an unplug at any other time is. `NullDevice` can go away during its
  next stop, configure or start to test each step.
- **A failed scan of a local folder is retried.** FSEvents reports a change once, so a scan that
  failed (a full disk, a locked database) used to lose those directories' changes until the
  next launch. The folder is now scanned whole a minute after a failed scan; a network folder
  still waits for its next poll.
- **A layout save that fails stays pending,** so the next save or the quit writes it, rather than
  losing the change once it's reported.
- **A library file SQLite can't read is moved aside.** The alert used to quit the app at every
  launch, with no way to recover inside it. It's renamed to `library.sqlite.unreadable-<time>`
  (with its `-wal` and `-shm`), a new library is made, and a discard notice in the new file
  names the old one, so plays, ratings and playlists can be recovered by hand.
- **A discarded state file is reported** in the config banner, not only logged.
- **Timeline commands that would act on no track beep and say so.** Reading every selected
  play's track to disable the menu items costs a query per menu check, so the commands stay
  enabled and fail loudly instead.

**The tools.** `FailureDrill` (Tools) runs each operation against a `--home` folder until it's
killed, and reopens everything as the app does to check it. `scripts/kill-test` sends seeded
`SIGKILL`s across the operations and fails on any database that doesn't pass
`PRAGMA integrity_check`, any config or state file that doesn't decode, and any music file that
differs from its pre-run hash once the tag journal is undone. `scripts/full-disk` fills a disk
image attached inside `~/Library/Caches/MusicPlayer`, never `/Volumes`. Neither runs in
`./scripts/check`.

## Alternatives considered

- **Following the system default output when the DAC goes mid-switch** — rejected for the
  reason in 0011: it would play out of the speakers at the DAC's volume.
- **Disabling timeline commands when every selected play is missing** — rejected: it reads every
  selected play's track whenever a menu is checked.
- **`PRAGMA quick_check` at launch,** to catch corruption deeper than the header — rejected: it
  reads the whole database: 184 ms of the 1 s launch budget for the 43k fixture
  library on Apple Silicon, with the file already cached. Damage inside
  a table shows as a failed query where it's read.
- **Retrying a failed local scan at once** — rejected: a full disk would make it spin.
- **Deleting an unreadable library file** — rejected: its stats are the one thing a scan can't
  recreate.

## Consequences

The table is the list to extend when a phase adds a failure path; each new row needs a test.
A device that reports itself still connected while a step fails is reported as an output
failure, as before; the hardware checkpoint on the ADI-2 shows which order the HAL uses. A
locked database at launch still quits after the alert, since the window can't open without
it. Files left outside the watched folders when their removal at launch fails are only logged,
and go at the next launch.
