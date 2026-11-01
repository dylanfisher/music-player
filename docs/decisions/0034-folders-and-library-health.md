# 0034. Folder tree from the index, and a health report of checks listed as sources

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md)

## Context

Phase 19 adds Reveal in Finder, folder browsing and a library health report. The library is
43k files on a NAS that can be slow or gone, so nothing here may read the disk: the index already
holds every path and every tag. The report has to list each group's tracks so they can be
played, revealed and fixed in the tag editor, like any other list of tracks, and phase 23 will
add a group for sync events that don't match.

## Decision

- **Reveal in Finder** is ⇧⌘R, as in Music and Swinsian, with Searcher's ⌥⌘R kept as the
  alternate. The track table's and the timeline's context menus have it too, acting on the
  clicked row or the selection holding it. It only calls `activateFileViewerSelecting`.
- **Folders.** Each watched folder's sidebar row opens into its subfolders: there's no separate
  mode, since the watched folders are already sidebar rows and a toggle would hide the
  playlists. `FolderTree` is built on the window's reader from the paths of the index's tracks
  (a folder holding only files that were never read has nothing to list, so it isn't shown).
  The tree is the folders and their children, a few thousand strings for 43k tracks; sidebar
  rows are made only when their parent opens, and kept by path so a rebuilt tree after a
  refresh keeps them open. A subfolder is a `.folder` source like a watched one. Its condition
  matches the canonical form, as for a watched folder, and also the folder byte for byte,
  since a share's paths mix forms (0032) and the canonical form of a precomposed name misses
  them. A saved subfolder opens the rows above it; one with no tracks left shows the library.
- **Health report.** `HealthCheck` lists the groups; `LibraryIndex.healthReport()` runs each
  check in one read transaction and returns each one's track IDs, plus lines for what isn't a
  track (a file never read, a playlist entry whose file left), 100 then a count. A new check is
  a case in `HealthCheck` and in the switch that runs it; nothing else changes.
  - *Unreadable*: `files.failure_kind` is set. *Warnings*: the file has a row
    in `warnings`.
  - *Missing Entries*: an entry with no track, as `missingEntryCount` counts it.
  - *Same Number*: the same album row (title and album artist, else track artist,
    as the index keys albums), disc (none counts as one value) and track number.
  - *Same Title*: the same title and artist, within a second of the same length.
    SQLite sorts by title, artist and length, and one pass links each track to the next when
    they match and are a second or less apart, so it's O(n log n), not pairwise. Titles match
    exactly; case and spelling variants aren't duplicates here.
  - *Track Gaps*: on one album and disc, fewer distinct numbers than the highest,
    so a lone "track 5" counts too.
  - *Album Artists*: the index splits an album by album artist, so this groups by
    album title and folder and counts the album artists set. A track without one isn't another
    value: it joins its track artist's album, which is usually the same, and No Album Artist
    lists it.
  - *Sample Rates*: one album row with more than one rate.
  - *No Art*: no embedded picture (the app shows no folder art). *No Album*, *No Album Artist*:
    the tag is missing.
- **Where it runs.** The report is built on a connection of its own, in a detached task, so the
  window's queries never wait for it. It runs on Check Library Health, at the end of a scan that
  stored or removed files (and the first scan's end if no report exists), and when a check is
  shown before any report has run. A network folder's polls that change nothing don't run it,
  so nothing runs it on a timer. Each run takes a session number in `HealthModel`, and a run
  that a newer one started after is dropped.
- **Listing a check.** The window's reader keeps the shown report's IDs in a temporary table,
  `temp.health_tracks`, and `.health(check)` is a source condition reading it, so the track
  table, panes, search, sort, play, reveal and the tag editor work on a check as on any source.
  The sidebar's Library Health row opens into one row per check, with a short name, its count
  at the row's end and what it finds as the tooltip; it isn't a source itself. What a check found that isn't a track is counted on the status bar and listed
  in the Problems window.

## Alternatives considered

- **Walking the folders on disk** for the tree. Rejected: a NAS walk is slow and can fail
  halfway, and folders with no tracks aren't worth listing.
- **Building every sidebar row up front.** Rejected: 4k rows of `NSOutlineView` items for a tree
  that's mostly closed.
- **Each check as a live SQL condition** instead of a stored report. Rejected: the title check
  isn't one, and the counts in the sidebar would then disagree with a list read later.
- **Passing the IDs in the query** (`IN (…)` or `json_each`). Rejected: a check can hold most of
  the library, and every pane and sort query would bind it again.
- **Building the report on the window's reader.** Rejected: it would hold up typing in the
  search field for as long as the report takes.

## Consequences

The counts are as of the last run: a tag edit or scan updates them when it ends, not while it
runs. A report is built on every scan that changes something, so a scan of a few files costs a
whole report, which the budget keeps under a second. Folder names that differ only in Unicode
form are one row in the tree.
