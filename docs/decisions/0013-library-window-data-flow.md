# 0013. The library window loads IDs off the main thread and rows a page at a time on it

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Phase 5's window shows a 43k-track library in an `NSTableView`, filtered by a sidebar folder,
three browser panes and search-as-you-type, sortable by any column. Budgets: interactive within
1 s of launch, a search keystroke under 30 ms (p95), a re-sort under 100 ms, under 250 MB
resident, and the 2015 MacBook Pro at roughly 2.5 times those times. Typing must never wait on
the database, and a rescan by the watcher must not lose the selection or scroll position. Phase 3
built the queries for this: sorted IDs, FTS5 prefix search and the pane lists.

## Decision

**Two connections.** `LibraryReader`, an actor with its own connection, runs every query whose
cost grows with the library: the sorted IDs, search and the pane lists. The main thread has a
second connection only for the table's rows, fetched a page of 100 at a time by primary key
(`rows(ids:)`), which takes well under a millisecond. Fetching rows synchronously means a row
never draws blank while scrolling. WAL mode lets both read while the watcher writes.

**IDs, not rows.** `BrowserModel` holds the visible tracks as an array of IDs; the table's row
count is its length. `RowCache` keeps at most 30 pages (3,000 rows) and drops the least recently
used page. New IDs or a library change clear it.

**The last change wins.** Each model change (pane, source, search, sort, refresh) takes a new
generation number before its queries; when they return, a change that a newer one overtook is
dropped. Queries on the actor run one at a time, so a burst of keystrokes costs one query each,
and only the last result reaches the view.

**Panes narrow left to right.** `TrackFilter` (folder, genre, artist, album, search) narrows the
tracks; each pane applies only the parts to its left. A selection a narrowed pane no longer lists
becomes All. Search narrows the table only, not the panes. Selections are saved by name, since IDs
change when the index is rebuilt; a saved name that's gone loads as All and is logged.

**Refreshing.** The watcher reports progress at most once a second and each scan's outcome. The
window refreshes at most every 2 s during a scan and at once when one ends with changes. The
selection is kept by ID. On a refresh the first visible track keeps its place on screen; on a
user's change the table scrolls to the selection, or the top.

**Playing.** A double-click on one row queues the whole visible list, starting there, so
previous and repeat-all work through it. With several rows selected it queues the selection in
table order, then the rows after the last selected one. Play Next inserts after the current
track. Queue edits are the engine's (play next, move, remove, in play order); removing the
current track moves on to the next, since the output can't keep playing a track the queue no
longer holds.

**Art** is read with `readArt` and decoded straight to the bar's size with ImageIO's thumbnail
call, in a cache of 64 images (`Artwork`). The full-size image is never decoded.

## Alternatives considered

- **Rows fetched asynchronously on the reader** — rejected: rows draw blank for a frame while
  scrolling, and a page is cheap enough that the actor hop costs more than the query.
- **All rows in memory** — rejected: 43k rows of strings is tens of megabytes held for nothing,
  and every rescan would reload them.
- **Cancelling an overtaken query** — rejected: SQLite would need `sqlite3_interrupt` from
  another thread, and the queries already finish in milliseconds. Dropping the result is enough.
- **Search narrowing the panes too, as Swinsian does** — not done yet: it costs three more
  queries per keystroke. Revisit if the owner misses it.
- **`NSArrayController` and bindings** — rejected: they want every row as an object.

## Consequences

- The main thread does SQLite work, but only primary-key page reads. A page is measured in the
  memory benchmark's scroll, which fetches every page.
- A table refresh after a rescan clears the row cache, so the visible page is read again.
- The status bar shows the track count, scans and problems; the total time and size Swinsian
  shows (ADR 0012) aren't there yet.
