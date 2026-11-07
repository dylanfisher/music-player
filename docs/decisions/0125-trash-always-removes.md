# 0125. Remove and Move to Trash always takes the tracks out of the library

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0050](0050-remove-from-library.md) (what leaves the library after the Trash)

## Context

The owner removed a track on the NAS with Remove and Move to Trash: the file was deleted, but
the track stayed in the table. 0050 took out only the tracks whose URLs `NSWorkspace.recycle`
named as moved, and the reply named none of the given URLs. A share with no Trash also deletes
the file and still reports an error. The owner: "either delete option should always remove it
from the library."

## Decision

- **A file moved is one gone from its path** once `recycle` has replied, checked off the main
  actor. The reply's URLs are not used.
- **Those tracks leave the index as in 0050**, not excluded, so a file put back from the Trash
  comes back with its stats.
- **The rest are removed from the library**, as Remove from Library does: excluded from scans
  until restored. The status bar says how many files the Trash refused and why.

## Alternatives considered

- **Matching the reply's URLs by standardized path.** Rejected: it fixes a mismatch but not a
  share that deletes and reports an error, and the file system is the fact either way.
- **Leaving refused files in the library, as 0050 did.** Rejected by the owner: the user asked
  for the tracks to go.

## Consequences

A track whose file the Trash refused needs Restore Removed Tracks… to come back, like one
removed from the library.
