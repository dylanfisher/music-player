# 0076. The local folders' launch scans run before the first sync

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The watcher syncs with the sync folder at start, after each scan and on each trigger (ADR
0038). Syncs and scans share one serial queue, so the database sees one writer at a time, and
at start the sync went first. A sync that merges a long log, as when a machine joins or comes
back after months, held the launch scan back for the whole merge: with another machine's 1M
plays pending, the scan of the fixture library started 4.9 s after launch on the build Mac,
where the merge alone takes 4.6 s. The old Mac's merge budget is 120 s. Until that scan ends,
files added or changed while the app was closed don't show, and `--report-launch` waits.

## Decision

While a local folder's launch scan is pending, the watcher starts no sync or push. Each scan's
end already asks for a sync, so the first one runs as soon as the last local launch scan ends.
The scan now reports its first progress 0.63 s after launch with the same merge pending,
against 4.9 s before. A network folder's launch scan doesn't hold the sync back.

## Alternatives considered

- **Every launch scan before the sync** — rejected in review: a network folder's launch scan
  that hangs on a dropped share would hold the sync and every push back for as long as it
  hangs, where before the sync ran ahead of it.
- **A queue for syncs of their own** — rejected: a sync maps paths by the folders' roots and
  writes the same tables a scan does, so the two would have to be made safe to run at once for
  a gain only at launch.
- **Syncing first only when the pending logs are short** — rejected: the size of a merge isn't
  known until the logs are read, and reading them is most of the cost.

## Consequences

- At launch, another machine's plays, ratings and playlist edits show after the local launch
  scans instead of before them. On a new index the merge then finds the tracks they added.
- A network folder's launch scan can still wait behind a long merge that starts after the
  local scans end: with only share folders, the sync goes first, as before. The share is the
  slow part of that scan anyway.
- A sync that hangs on a dropped share still holds the scan queue; phase 32e.4 covers file
  access that never returns.
