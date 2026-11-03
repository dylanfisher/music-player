# 0080. Signposts on the hot paths, and a log of main-thread stalls

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The benches run on fixtures and simulated latency. The owner's library is 43k real files on a
NAS, played on a 2015 MacBook Pro, and the hitches that matter there are the ones no bench
shows. Nothing in the app marked its work for Instruments, so a trace from the old Mac showed
stacks without the operations around them, and nothing recorded a hitch when the owner saw one.

## Decision

`Interval` in Log names each marked operation once: an art load, a row page fetch, a browser
refresh, a query a list waits for (sorted IDs, totals, pane entries, the palette's names), a
palette ranking and a scan batch's store. `signposted(_:_:)` runs a closure inside an
`OSSignposter` interval in the Points of Interest category, and notes it in `IntervalLog`,
which holds the open intervals and the last 64 that ended. The time from a play action to the
first sample is phase 32a's path; it gets its interval when 32a merges.

`StallDetector` puts one run-loop observer on the main loop for every activity in the common
modes. Every activity is a mark, and the loop is busy from one mark to the next except from
going to sleep to waking, so event handling between the loop's exit and its next entry counts
as well. A busy stretch over 100 ms is logged at notice level, once it ends: its length, the
intervals that overlapped it with the time each overlapped, the last command the dispatcher
ran, and the type of the event `NSApp` was handling. The names are the app's own, so they're
logged public; key characters and paths never are.

## Alternatives considered

- **A watchdog thread that samples the main thread's stack** — rejected: a cheap sample of
  another thread's stack needs thread suspension and symbolication in-process, and a watchdog
  needs a timer, which wakes the idle app (the idle-wakeup budget is 1 a second).
- **A watchdog timer that pings the main queue** — rejected for the same wakeups, and it would
  only say that a stall happened, not what ran.
- **Signposts without the interval log** — rejected: the stall log could then name only the
  command, which doesn't separate a slow page fetch from a slow refresh.

## Consequences

- A main thread that never returns is never logged; a hang has its spindump instead.
- Each interval takes a lock twice, which costs well under a microsecond against work that
  takes milliseconds.
- The owner reads the stalls with `log show --predicate 'subsystem == "com.dylanfisher.MusicPlayer" AND eventMessage CONTAINS "stalled"'`.
