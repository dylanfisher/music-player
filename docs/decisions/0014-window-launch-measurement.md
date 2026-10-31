# 0014. The window benchmarks launch the real app, which measures itself

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Phase 5 budgets the launch to an interactive window (< 1 s, < 2.5 s on the old Mac) and resident
memory with the library loaded (< 250 MB), both for the 43k fixture library. Bench runs on the
build Mac and, prebuilt, on the 2015 MacBook Pro. The app tier can't be imported by Tools
(ADR 0004), so Bench can't build the real window in its own process, and a window put together
from the features in Bench would leave out what the app does at launch.

## Decision

The app takes `--measure-window`. When the track table first draws rows, it records the time
since the kernel started the process (`kinfo_proc.p_starttime`, so loading the binary counts) and
its physical footprint. It then scrolls through every row a screenful at a time, drawing each,
decodes each album's art through the same `ArtworkLoader` the now-playing bar uses, records the
footprint again, prints one JSON line and quits.

Bench scans the fixture library once, then for each of three runs makes a settings file that watches
it, copies the index beside it, and launches the app found beside the Bench executable (the bare
executable `scripts/bench` builds, else the one inside a copied `MusicPlayer.app`). The launch
budget takes the median of the three; the memory budget takes the largest footprint after scrolling.

The browser model's search and re-sort are measured in Bench's own process, through
`BrowserModel` on the main actor, since what they cost is the model's queries and nothing the
app adds.

## Alternatives considered

- **An os_signpost read with Instruments** — rejected: Bench has to run unattended on both Macs
  and print a number against a budget.
- **Building the window offscreen in Bench** — rejected: it would measure a second composition of
  the features, not the app's, and Bench can't import the app.
- **Timing from `main` instead of the process start** — rejected: it leaves out dyld and the
  frameworks, which are a large share of a cold launch on the old Mac.

## Consequences

- The window opens on screen during the benchmark, three times, for several seconds each.
- The runs aren't cold in the page-cache sense: the fixture files and the index were just read.
  The owner's checkpoint reports a real cold launch against the NAS library.
- The app's launch work (the output, the watcher's no-change rescan) runs during the scroll, so
  the memory figure includes them, as it would in use.
