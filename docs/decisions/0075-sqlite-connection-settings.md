# 0075. Library connections map the file and sort in memory

- **Date:** 2026-11-03
- **Status:** accepted

## Context

Phase 32c asks whether the settings a connection leaves at SQLite's defaults cost the library
time. `Database` set only WAL, `synchronous` and foreign keys, and nothing ran `ANALYZE` or
`PRAGMA optimize`. The defaults here are the system SQLite's, which on macOS 27 (3.54) are a
2,000-page cache, temporary tables and indexes in a file, no memory mapping (with a 1 GB limit),
and a 32 KB `journal_size_limit`.

Each candidate ran on its own through the sort, pane, search, smart playlist, history, palette,
health, scan and reader benchmarks, against the same build without it, on the build Mac the same
hour. Three baseline runs set the spread: about 5% on most, 10% on the timeline page.

## Decision

Every read-write connection sets `mmap_size` to 256 MB and `temp_store` to memory, once in
`Database.init`.

| Benchmark | Baseline (3 runs) | `mmap_size` | `temp_store` | both |
|---|---|---|---|---|
| Health report (p95) | 0.24–0.25 s | 0.21 s | 0.19 s | 0.16 s |
| Timeline page (p95) | 2.18–2.50 ms | 1.88 ms | 2.48 ms | 1.86 ms |
| Browser pane (p95) | 0.52–0.56 ms | 0.47 ms | 0.54 ms | 0.45 ms |
| Sort every column (p95) | 42.5–45.3 ms | 40.0 ms | 45.7 ms | 42.0 ms |
| History (p95) | 19.1–20.7 ms | 18.9 ms | 21.9 ms | 21.2 ms |

The rest moved within the spread either way.

## Alternatives considered

- **A 16 MB `cache_size`** — dropped: no benchmark moved past the spread. The pages a query
  reads are in the system's file cache already, so a larger SQLite cache only copies them again.
- **`ANALYZE` after a scan, or `PRAGMA optimize`** — dropped: with statistics on the fixture
  index no benchmark moved, and statistics could change a plan the benchmarks have tuned for.
  Before SQLite 3.46, which macOS 12 predates, `optimize` analyzes only the tables its own
  connection has queried, so its result would depend on which connection ran it.
- **`journal_size_limit`** — dropped: the system SQLite already limits the log to 32 KB after a
  checkpoint; a scan with the reader open left it empty.

## Consequences

- A mapped page counts as resident while used, but it is the file's own clean page, which the
  system can drop; the window's memory benchmark measures the footprint, which leaves it out.
- An I/O error on a mapped page raises SIGBUS instead of returning an error. The index lives on
  the internal disk, in Application Support, so this is the same risk as any mapped file there.
- A build of SQLite with a lower mapping limit maps less, or nothing, without an error. Each
  library connection reads the size back and logs an error with both sizes when it is lower,
  then carries on. The macOS 12 limit is checked at the 32f checkpoint.
- Large sorts and `GROUP BY`s use memory instead of a temporary file: at 43k tracks a few MB.
