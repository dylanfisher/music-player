# 0054. The Rescans column offers a fixed list of intervals

- **Date:** 2026-11-02
- **Status:** accepted

## Context

Row 26.3 makes the Watched Folders table's Rescans column editable in place, as a popup of the
intervals the settings schema allows, plus "Watch only" for local folders if the schema allows
it. The schema allows any whole number of minutes from 1 to 1440
(`WatchedFolder.pollIntervalRangeMinutes`) for a network folder. A local folder is watched with
FSEvents and never polled; its `pollIntervalMinutes` is ignored.

## Decision

- **The popup lists 1, 5, 15 and 30 minutes, and 1, 2, 6, 12 and 24 hours**
  (`GeneralModel.rescanIntervalsMinutes`), filtered by the schema's range so the range stays the
  one fact. A popup of 1440 items can't be used.
- **A value the config file sets that isn't in the list is added to that folder's popup**, so the
  popup shows the interval in effect and choosing another doesn't lose it by accident.
- **Only network folders get the popup.** The schema has no polling for a local folder, so there
  is nothing to choose and no "Watch only" item: a local folder's cell stays the label
  "On change".
- The popup writes `pollIntervalMinutes` of that folder in `library.watchedFolders`, the same
  value the config file holds, and leaves the folder's other keys as they are.

## Alternatives considered

- **A number field in the cell** — rejected: the row asks for a popup, and a field invites values
  outside the range that the schema then refuses.
- **Polling local folders on a timer too, to give them a choice** — rejected: FSEvents already
  reports their changes, and it is a schema change outside this row.

## Consequences

Any other interval is still set in the config file. Adding an interval to the popup is a change
to the list, kept inside the schema's range by a test.
