# 0053. The Problems window's rows have actions, and a dismissed line stays dismissed

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0033](0033-import-from-other-players.md), [0034](0034-folders-and-library-health.md),
  [0050](0050-remove-from-library.md)

## Context

Row 26.1 asks for actions on the health report's problem rows: Dismiss for problems the user
doesn't care about, Remove from Library for missing tracks, and Locate… for an import's misses.
The Problems window was a text view of lines, from the scans, the stored file issues, the health
check shown, the last import and the sync.

The owner's case was a Swinsian import that listed a `.dsf` file under the watched `dsd` folder
as not in the library. The cause wasn't the mount path, the share mapping (0028), NFC or a scan
still to run: the scanner reads only `audioFileExtensions`, and DSF and DFF wait for phase 12,
so no such file is ever in the index.

## Decision

- **A miss in a format the scanner skips is listed apart**, as "not in the library, a format
  this app doesn't read yet", and the preview counts it. No prefix or folder can match it, so
  it gets no Locate.
- **The Problems window is a table**, a row a line, with Dismiss, Remove from Library and
  Restore under it. ⌘C copies the rows selected. A button is on only when it applies to every
  row selected, so one click never does two different things.
- **Dismiss** stores the line, as the window shows it, in a table of its own schema part,
  `dismissed_problems`, so it stays dismissed after a relaunch and when a later scan or report
  finds the same problem. A dismissed line leaves the list and the problems button's counts.
  Any row can be dismissed. A problem whose line changes, such as a scan failing with another
  reason, shows again.
- **Remove from Library** is on a Lost Stats row: a path whose file left with plays, a rating or
  playlist entries. It adds the path to `removed` (0050), so its stats stop waiting in Lost
  Stats and a file that comes back at that path stays out until restored. Lost Entries rows
  name a playlist entry, not a track, and get only Dismiss.
- **Restore** is on a Removed row, as Restore Removed Tracks… does it: the path leaves
  `removed` and its folder is scanned. This is the Library Health Restore that 0050 left to
  this row.
- The health report keeps the path ID of each Lost Stats and Removed line it lists, so a row
  acts on the path it names. The rows of a check show only while the check is the source, as
  before.

## Alternatives considered

- **Keying a dismissal by path and kind** instead of the line. Rejected: the lines come from
  scans, file issues, imports, the sync and the health checks, with no common key; the line is
  the one thing every row has, and it's what the user saw.
- **Dismissing for the session only.** Rejected: the health report and the stored file issues
  come back on every launch, so a problem the user doesn't care about would too.
- **Remove from Library on Lost Entries rows** as removing the entry from its playlist.
  Rejected: that isn't removing a track from the library; the playlist editor already removes
  entries.

## Consequences

Dismissed lines are this machine's, as `removed` is. There's no list of dismissed lines to undo
one from; deleting the table's rows brings them back.
