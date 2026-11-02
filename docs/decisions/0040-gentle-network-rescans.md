# 0040. Network folders: no rescan at launch, an hourly poll by default

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0009](0009-scanning-and-watching.md) (Watching)

## Context

The owner's library is 43k files in thousands of folders on an SMB NAS. A rescan lists every
folder, one round trip each, and the watcher rescanned every network folder at launch and every
15 minutes. On the 2015 MacBook Pro, the launch rescan kept the NAS busy enough that a play
click waited more than 27 s. Swinsian, the owner's reference player, doesn't rescan at launch,
and the owner runs its periodic check every 24 hours. The owner: "I'd prefer to do less
scanning. Default should be more like 60 minutes."

## Decision

**No rescan of a network folder at launch.** A network folder the index holds files for shows
them at once, and its first poll comes `pollIntervalMinutes` after the watcher starts. One the
index holds nothing for (just added, or never scanned) is scanned at once. The watcher sends
`keptIndex` for each folder it leaves, so the first health report still runs and
`--report-launch` still ends. `library.rescanNetworkFoldersAtLaunch`, off by default, brings
back the launch rescan. Local folders are unchanged: FSEvents reports nothing from before
launch, so they're still scanned whole at launch.

The rest of start is unchanged: the shares are located, paths rewritten for a share mounted
somewhere new, files outside the watched folders removed, and a sync runs. The sync never
waited for the launch rescan: start marks it due, and the first `advance` runs it before any
scan. A share that moves while the app runs is still polled at once at its new path.

The watcher restarts when the library settings change, and that counts as a start: adding a
folder scans only the new one.

**An hourly poll by default.** `WatchedFolder.defaultPollIntervalMinutes` is 60. The range
stays 1 to 1440, so 1440 matches the owner's Swinsian. A folder already in the config keeps the
interval it was saved with.

**A running scan yields to playback in place.** With `library.pausePollingDuringPlayback` on,
playback starting pauses a running network scan before its next directory or file (files being
read finish), and stopping resumes it where it was. It never starts over, so it finishes after
any number of pauses. This was already so; a test now covers it. While it's paused, other scans
and syncs wait behind it, as before.

**Rescan Now** (File menu, palette) scans every watched folder whole at once, ignoring the poll
timer and, since the owner asked, the playback pause setting. A running whole scan of a folder
counts for that folder and resumes if playback paused it. It still waits while a track starts,
which takes seconds, so a play click isn't slowed by the scan it asked for. It doesn't run from
`music-player://` links: it overrides the playback pause, so a page opening it in a loop could
keep the NAS busy while the owner listens. `music-player rescanNow` runs it from the command
line, which only this user's processes can reach (ADR 0036).

## Alternatives considered

- **Rescan at launch after a delay** — rejected: it still walks the share near the first play,
  and the owner asked for less scanning, not later scanning.
- **Persist each folder's last poll time and resume the schedule across launches** — rejected:
  more stored state for little gain; one interval after launch is close enough.
- **Rescan Now from links** — rejected, for the reason above; the command line covers
  scripting.
- **Change the stored interval of existing folders to 60** — rejected: pre-release data has no
  migrations, and the owner may have chosen 15.

## Consequences

Changes made on the NAS while the app was closed appear up to one interval after launch, or at
once with Rescan Now. The
owner's existing config keeps its saved interval until edited.
