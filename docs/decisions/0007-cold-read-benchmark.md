# 0007. Measure "cold" tag reading as a first read in a fresh process

- **Date:** 2026-10-30
- **Status:** accepted

## Context

The plan asks for a benchmark that parses the 43k-file fixture library cold. A truly cold read
means evicting the files from the page cache, which only `sudo purge` does, and the benchmark
runs unattended without root. The fixture library is about 550 MB, so it stays cached between
runs on most Macs.

## Decision

The benchmark reads the library at the default fixture location, which `Bench` only stats (to
confirm it's current) before the timed pass, so the timed pass is the first read of those files
by this process. It then parses everything a second time and reports both passes, throughput,
and bytes and reads per file. If the library had to be generated in the same run, a note says
the first pass read pages the writes left in the cache. The name says "first read in this
process", not "cold". Files are parsed on one thread, so the number is the parser's and the
file system's cost, not a measure of parallelism.

## Alternatives considered

- **Run `purge` before the pass** — rejected: it needs sudo, so it would prompt or fail unattended.
- **`F_NOCACHE` on each file** — rejected: it stops new pages being cached but still serves pages
  that are already cached, so it doesn't make a read cold.
- **Generate a fresh library and read it** — rejected: writing leaves every page cached, which is
  warmer than reading an existing library.

## Consequences

On a Mac with the library cached, the two passes measure nearly the same, and the number is the
per-file cost of `open`, `fstat`, `pread` and parsing. A true cold-cache number, and the NAS
number that matters for phase 3, have to be measured by hand: `sudo purge`, then
`./scripts/bench metadata`.
