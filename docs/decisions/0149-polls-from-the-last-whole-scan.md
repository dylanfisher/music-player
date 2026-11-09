# 0149. A network folder is polled an interval after its last whole scan, across launches

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0040](0040-gentle-network-rescans.md) (no rescan at launch, and the rejected
  persisted poll time), [0009](0009-scanning-and-watching.md) (Watching)

## Context

ADR 0040 started each indexed network folder's first poll `pollIntervalMinutes` after launch,
and rejected storing a poll time as "more stored state for little gain". The owner's library
and dsd folders poll every 1440 minutes with launch rescans off, and on 8 Nov the app was
relaunched many times to install builds. Each relaunch pushed the poll another 24 hours out,
so the share was never polled. After the owner converted 17,518 ALAC files to FLAC, the app
removed the gone `.m4a` rows when it saw they were missing, but about 17,500 new `.flac` files
went unread until the owner ran Rescan All. The owner wants the interval to mean "at most once
per interval, by the clock".

## Decision

**The index stores when each folder's last finished whole scan started.** The `scans` part's
`scanned_folders` row gets `started_seconds`, by the wall clock. As before, a whole scan deletes
its folder's row as it starts. When its walk finishes, it writes the row back with the time the
scan started. Launch scans, polls, Rescan All and Rescan of one folder all go through the same
scan, so all of them record it. A move of a share carries the time with the row.

**The next poll is that time plus the interval.** The rule is the same at launch and while
running: a whole scan's start plus `pollIntervalMinutes`. It uses `Date`, so time the Mac sleeps
or the app is quit counts. A relaunch 3 hours after a 24-hour folder's scan polls 21 hours
later. A scan of a folder's subtrees, from a tag edit, isn't a whole scan and leaves the poll
where it was.

**A poll that fell due while the app was quit runs 2 minutes after launch.** This is
`WatchState.overduePollDelaySeconds`. The hold is added to the existing hold while a track
starts, so the walk doesn't slow the first track's read, which was ADR 0040's reason for not
rescanning at launch. A saved time ahead of the clock, as after the clock was set back, counts
as due.

**Unchanged:**
- A folder with no row is scanned at launch at once. That covers one just added, never scanned,
  or whose last whole scan was cut short.
- A folder set to never isn't polled.
- Each Mac keeps its own index, so its own times, and nothing syncs them.
- `library.rescanNetworkFoldersAtLaunch` stays. It now means "scan at launch at once, without
  waiting for the interval or the 2-minute hold". It still skips a folder set to never.

## Alternatives considered

- **Leave the time unchanged when a scan is cut short or fails, and keep it beside a separate
  "finished" flag.** Rejected. A cut-short scan already deletes the row, and the folder is
  scanned at launch, which is stricter than an unchanged time and needs no second column. Its
  start time is never recorded. A poll that fails while the app runs waits an interval from
  its own start, in memory, as a failed poll did before.
- **Measure from when the scan ended.** Rejected. The owner asked for the start. With start
  times, the rule at launch and while running is the same.
- **Drop `rescanNetworkFoldersAtLaunch`.** Rejected. The owner may still want a launch scan
  with a long interval, and keeping the setting costs nothing.
- **Hold an overdue poll until playback settles, with no fixed delay.** Rejected. With nothing
  playing at launch, it would start at once, in the middle of the first click's read. The fixed
  hold plus the existing hold while a track starts covers both cases.

## Consequences

- A relaunch no longer postpones a poll.
- Changes made on the NAS while the app was quit appear at most one interval after the last
  whole scan, and no sooner than 2 minutes after launch.
- An index from before this change has no `started_seconds`. Its scans part is rebuilt empty,
  so each network folder is scanned once at the next launch.
- A whole scan that takes longer than its interval is due again as soon as it ends. With the
  owner's 1440 minutes, that doesn't happen.
