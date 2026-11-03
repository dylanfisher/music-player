# 0086. A refresh connection, our own table stripes and a read-ahead at launch

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The 32f checkpoint on the 2015 MacBook Pro (2 cores, 4 threads, macOS 12) left four problems.
The second of two search keystrokes during a scan took p95 265 ms against 150 ms, and 20 ms
idle. Every launch logged a 100–196 ms main-thread stall with no marked interval. A cold launch
took 3.52 s against 0.86 s warm. Idle CPU was 0.11% of a core against 0.10%. Toggling the
sidebar stalled once for 100 ms.

Measured on the build Mac:

- A keystroke during a scan waits only when it lands while the browser refreshes. The refresh
  rereads every pane, the sorted IDs, the totals and the file issues, which take 120–500 ms under
  a scan, and `LibraryReader` is one actor, so the keystroke's queries queue behind them. The
  slowest keystroke was 363 ms against 23 ms with refreshes turned off. Neither the scan's
  reader count nor its priority changed the result: 30 readers instead of 10, and the scan at
  `.utility` instead of the bench's default, both measured within noise.
- The launch stall is the window's first frame. AppKit's own alternating row stripes take
  160–200 ms of main-thread drawing there. The cost grows with the table's area, and it goes
  away with stripes off, or with `drawBackground(inClipRect:)` overridden, even by one that only
  calls `super`.
- A launch reads 88% of the 47 MB fixture index before the first rows, through the mapping, a
  page fault at a time. From a cold cache that is a random read per page.
- Idle, the app uses 0.01% of a core with no idle wakeups here.
- A sidebar toggle takes about 20 ms here. A trace shows it all in AppKit: the split view and
  the table's column widths laid out again, the header view rebuilding its subviews, and every
  visible cell drawn again.

## Decision

`LibraryReader` opens a second connection, `refreshes`. `BrowserModel` runs a reload for
`.libraryChanged` on it, and `LibraryBrowser` reads that change's totals and the issue count on
it. A keystroke, a click or a sort stays on the first connection, so it no longer waits for a
refresh, and the refresh's late result is dropped by the generation check as before. Edits stay
on the first connection; a read on the second that starts after an edit commits sees it, since
both read the same WAL file.

`KeyTableView`, the track table and the panes, draws its alternating rows itself in
`NSColor.alternatingContentBackgroundColors`, a filled rectangle a row, below the last row too.
It looks the same as AppKit's.

At launch, before the first connection opens, `Database.readAhead(at:)` asks the kernel to read
the whole index file into its cache (`F_RDADVISE`) and returns at once. The queries then find
their pages cached, or wait for a read already under way. A cold launch of the fixture library
went from 0.43 s to 0.365 s here. The old Mac's SSD reads at random much slower than in
sequence, so the gain should be larger there. A failed hint is logged and the launch goes on.

The launch's steps are signposted (`launchSettings`, `launchWindow`, `launchServices`), so the
stall log and Instruments name them. The launch bench's index copy is an APFS clone, which
shares the blocks but none of the cached pages, so each launch already reads the index cold.
The bench now checks this with `mincore` before each launch and fails if more than 10% of the
copy is cached. The frameworks and the app's binary stay warm; only `sudo purge` drops those,
so the old Mac's checkpoint keeps the true cold number.

The old Mac's idle CPU budget is 0.15% of a core, set from its 0.11%. Nothing of the app's own
wakes when idle here, and 0.25 wakeups a second is a quarter of the wakeup budget.

The sidebar toggle is left alone. Its cost is AppKit's relayout and redraw of the window's
content, like the live resize budget set in 32f.

The scan's readers stay at one per thread: 4 on the old Mac. The app scans at `.utility` and
queries at `.userInitiated`, which already gives the scheduler the order the user wants. The
reader bench scans at the default QoS, a level higher than the app does, so it overstates the
contention a little.

## Alternatives considered

- **Interrupting a refresh's query (`sqlite3_interrupt`) when the user types** — rejected: the
  interrupt hits whatever statement runs on the connection when it lands, which can be the
  keystroke's own query.
- **Ending a superseded refresh at its next query** — rejected as not enough: the query already
  running still holds the actor, and those take hundreds of milliseconds under a scan.
- **Fewer scan readers on few cores** — rejected: it didn't change the keystroke here, and it
  would slow the old Mac's scan.
- **Row views that draw their own background** — rejected: no stripes below the last row, which
  AppKit's tables and Swinsian both draw.
- **Reading the index ahead with a background `read` loop** — rejected: `F_RDADVISE` does the
  same in the kernel with one call and no thread.

## Consequences

- The app holds one more SQLite connection, with its own page cache of up to 2 MB.
- A refresh and a keystroke can run their queries at once, on two cores.
- The whole index enters the file cache at launch, the play history too, though the first rows
  don't need it. That memory is the system's cache, not the app's footprint.
- If a later macOS changes the alternating colors, the table follows
  `alternatingContentBackgroundColors`, which AppKit's stripes use too.
