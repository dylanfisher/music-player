# 0212. Filtering and finding downloads and recommendations

- **Date:** 2026-11-19
- **Status:** accepted
- **See also:** [0200](0200-upgrading-to-flac-automatically.md) (the upgrades' pass),
  [0205](0205-recommendations-in-the-player.md) (the Recommendations window)

## Context

The owner (2026-11-19) asked for three things in the Downloads and Recommendations windows: a
search bar that filters "results that have been loaded in those screens", not a full search;
opening a row in All Music "if it's been downloaded"; and in Downloads, a count of the albums
eligible for Upgrade to FLAC Automatically while it's on.

## Decision

**The filter is local.** Each window has a search field that keeps the rows it was given whose
visible text holds every typed word, ignoring case and accents. Downloads matches the album
(artist, title, year), format, user and state; Recommendations the artists, title, year, label
and styles. The rule is `ListFilter`, in DisplayText, which the Shortcuts pane and Other
Releases… now share. Neither the service's query nor a stored setting changes, and the field's
text isn't kept. In Recommendations, the last row coming into view doesn't read the next page
while the field has words: with few rows kept, it would read the whole list a page at a time.

**Show in All Music goes by Discogs release.** In Downloads it applies to an imported job, or
an upgrade, whose old album is in the library; in Recommendations, to a row whose release
Downloads lists as imported. The release looked up is the one the files carry: the release the
owner tagged them as in the tagger, else the job's. `LibraryIndex.albumID(discogsRelease:)`
finds the album off the main thread, and the app selects its first track, as the palette's Go
to Album does. A release no album carries says so in the window, rather than doing nothing.

**The upgrade count is the pass's own rule.** `AutoUpgrades.queueable` is `next` with no room
limit, counted at the end of each pass from the jobs as they are then, so Never Upgrade, misses
not yet due, skipped releases and live jobs are left out exactly as the pass leaves them out.
With every slot taken, a pass recounts from the candidates it read last, whatever has
changed since, so it reads the library no more often than it did before the count. Only a
pass with nothing read yet, after a launch with the slots full, reads them.

## Alternatives considered

- **Filtering on the service.** Rejected: the owner asked for the rows loaded, and the
  service's filters are the Recommendations bar's already.
- **Finding the album by the upgrade's old paths.** Rejected: an imported job's new files are at
  paths the service doesn't list, and the release id is what both windows have.
- **Counting only when a slot is free.** Rejected: the count would freeze, or vanish, while the
  upgrades are full, which is most of the time.

## Consequences

- While the slots are full, the count can lag the library: an album just upgraded is counted
  until a slot frees and the pass reads the candidates again.
- An imported album retagged since as another release isn't found, and the window says so.
