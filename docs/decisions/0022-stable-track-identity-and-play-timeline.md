# 0022. A permanent ID per path keys the stats; every play is listed on a timeline

- **Date:** 2026-10-31
- **Status:** accepted
- **Amended by:** [0023](0023-failure-table.md): the failure table, and the failures phase 14a
  changed how this reports. [0026](0026-sync-identity-is-the-relative-path.md): paths are
  stored in NFC, and a matched move deletes the stat-less row a scan added.
  [0028](0028-network-folders-by-share.md): a share's new mount point rewrites the paths.
  [0038](0038-sync-logs.md): other machines' events add rows, plays and history, and a
  merged move deletes a path that had stats. [0056](0056-history-lists-recorded-plays.md):
  History lists only tracks with a row in `history`.
- **Supersedes:** "key stats by path" in [0008](0008-library-schema-identity-and-stats-by-path.md)
- **Amends:** [0018](0018-playlists-and-stats.md)

## Context

The stats key on the file's path (0008) because `files.id` is a row number that every index
rebuild, and every file leaving and coming back, hands out again. That costs three things:
`history` stores the whole path in every row and again in its index, about 250 bytes a play, so
1M plays would take about 250 MB; `files.added_seconds` is lost on every rebuild, so Date Added
shows the rebuild's time; and every stats join compares long path strings. The owner wants every
play listed, not only one row per track, and expects the log to reach a million rows.

## Decision

### Identity

- **`paths` (`id INTEGER PRIMARY KEY`, `path TEXT UNIQUE NOT NULL`, `added_seconds REAL NOT
  NULL`) is a stats table**, so an index rebuild keeps it. The scanner looks a path up there, or
  inserts it with the current time, and stores that ID as `files.id`, which refers to it.
  `added_seconds` moves off `files`, so Date Added survives a rebuild.
- **Rows are never deleted.** A file that leaves the index and comes back gets its old ID, its
  Date Added and its stats. A renamed or moved file is a new path and a new ID, as before; 0008's
  consequences for moves still hold.
- **Paths are compared byte for byte.** A precomposed or decomposed spelling, or another case,
  reached by some other route would get a second ID. That's accepted rather than normalized:
  the scanner stores the path as it lists it, and the player plays and records `files.path`, so
  both reach the same bytes.
- **No cap on `paths`.** It grows by one row per distinct path the library has ever seen: a new
  file, a rename, a move or a remount at another path. A row is the path plus two numbers, stored
  again in the `UNIQUE` index, about 250 bytes for the owner's paths, so 43k files take about
  11 MB, and remounting the whole library elsewhere once doubles it. An insert costs O(log n) in
  the table's size. A cap would have to delete rows, which would hand a returning file a new ID
  and lose its stats, the thing the table exists to prevent.
- **A play of a path the index never saw** (a file opened from Finder) inserts the path too, so
  the play has an ID to key on. If that file is scanned later, its Date Added is when it was
  first played.
- `files.path` stays: the folder ranges and the scanner's lookups use its index, and the whole
  `files` table is a copy the next scan can rebuild.

### Stats by ID

- `plays (path_id PRIMARY KEY …)`, `ratings (path_id PRIMARY KEY …)` and `playlist_entries
  (playlist_id, path_id, position)` key on `path_id`, which refers to `paths`. Joins from
  `files` and `tracks` become `t.file_id = path_id`, an integer lookup. The History source, the
  manual playlist source, playlist order, the smart rules and the missing-entry count all use
  it. The library's own APIs for ratings and playlist entries take track IDs, which the views
  already hold, instead of paths.
- **`history (id INTEGER PRIMARY KEY, path_id INTEGER NOT NULL, played_at INTEGER NOT NULL)`**,
  whole seconds since 1970, with an index on `path_id`. Rows are only appended, so `id` order is
  the order plays were recorded, and nothing indexes `played_at`. A play is about 20 bytes in the
  table and 12 in the index.
- **History (one row per track) reads `plays` where `last_played_seconds` is set**, so its cost
  follows the tracks played, not the length of the log. With every fixture track played it is a
  sort of the whole library, so it reads them in order from an index on `last_played_seconds`,
  and a Last Played sort breaks ties on the ID alone rather than by artist and album.

### The one-time discard

- The stats SQL changes, so a database from an earlier build has its stats rebuilt, as 0008
  says. That is now explicit: before dropping them, the rebuild counts the rows of the old stats
  tables, logs the counts, and records them in `schema_discards`, which sits beside
  `schema_identity`, keeps one shape and survives every rebuild. The library window reads the
  records when it loads, adds them to the status line and the problems list for that session,
  and deletes them only once shown, so each shows once even when the command line scan did the
  rebuild, and a crash before then shows it next time. Nothing is
  recorded when the old tables were empty.

### The play timeline

- **Its own sidebar item, Timeline, in the Library group after History**, saved as the source
  `timeline`. A second mode of History would need a switch that History alone has; a sidebar
  item is a row like the others, which Back and Forward step through.
- **Every play, newest first**, 200 at a time by key (`WHERE id < :last ORDER BY id DESC LIMIT
  200`), never `OFFSET`, so a page costs the same at any depth and new plays don't shift the
  pages already loaded. The next page loads as the table draws its last rows. A new play is added
  above the loaded rows. A loaded play is three numbers (history ID, path ID, time); what a row
  shows is read with its page into a cache of 20 pages, so scrolling a million plays holds a few
  thousand tracks. A library change empties the cache, so only rows drawn again are read.
- **Columns:** Played (date and time), Title, Artist, Album and Time. They aren't sortable or
  configurable: the order is the log's, and the panes and search don't apply. The panes are
  hidden and the search field is off while it shows; the sort commands are off.
- **A play of a file no longer in the index stays**, shown by its file name, dimmed, with "Not
  in the library" in the Artist column, so pages stay full.
- **A row's identity is its history ID**, since the timeline repeats tracks. For each action:
  - *Selection* is kept by history ID across a new play, a page load and a library change. It
    is the timeline's own; the track table keeps its selection while the timeline shows.
  - *Play* (double-click, Return, the context menu) queues the loaded rows by the track table's
    rule (`playOrder`) over row positions, leaving out missing rows. A track listed twice plays
    twice, as the rows say.
  - *Play Next* queues the selected rows' files in row order, repeats included.
  - *Drag* carries the dragged rows' track IDs in the app's own pasteboard type, missing rows
    carrying none, so a manual playlist in the sidebar can take them; the playlist leaves out
    tracks it has. Nothing drops onto the timeline.
  - *⌘⌫* is off. The log is append-only, and deleting a play would leave the counts it added.
  - *Rate, Add to Playlist, New Playlist from Selection, Edit Tags, Reveal in Finder and Copy
    Path* act on the distinct tracks of the selected rows, in row order, leaving out missing
    rows.
  - Those commands are on while any row is selected, even only missing ones, rather than read
    every selected play's track each time a menu is checked; with only missing ones they beep
    and say so in the status bar ([0023](0023-failure-table.md)).
  - *Go to Item* lists the library's tracks, not the plays; choosing one leaves the timeline
    for the library (amended in 0016).
  - *Type-to-select* is off: there is no sort column to type into.
- The status line counts the plays: the last history ID, since rows are never deleted.

### Budgets

With 1M synthetic plays over the 43k fixture tracks, generated under `.build`: one timeline
page p95 < 5 ms, the History source p95 < 30 ms, recording a play p95 < 2 ms, and the history
table plus its index < 40 MB.

## Alternatives considered

- **Keep keying by path** — rejected for the three costs above.
- **A hash of the path as the ID** — rejected: 64-bit hashes can collide, and a collision would
  merge two tracks' stats with no way to tell.
- **`AUTOINCREMENT` on `paths`** — not needed: rows are never deleted, so the next ID is always
  new.
- **Deleting `paths` rows no file or stat refers to** — rejected: a file that comes back after
  a NAS outage would get a new ID and a new Date Added, which is what this record fixes.
- **Carrying the old stats over by path** — rejected by the pre-release rule: stored data has
  one shape, and a one-off conversion is a migration.
- **Paging the timeline with `OFFSET`** — rejected: its cost grows with the depth, and a play
  recorded while scrolling would shift every later page by a row.
- **Showing the timeline in the track table** — rejected: the table identifies rows by track ID
  and caches them by ID, and its sort, panes and search have no meaning for a log.

## Consequences

The owner's stats from earlier builds are dropped once, with the counts shown. Date Added now
means when the app first saw the path. Two plays recorded in the same second keep their order by
ID. Moving files still loses their stats; a path rewrite would now update one row per file in
`paths` instead of every stats row.
