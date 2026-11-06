# 0109. Listening Stats: rolling periods, the totals beside the chart, a named list

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0102](0102-listening-stats.md) (the periods, the cards' flow, a saved list)

## Context

Part 48b. The owner asked for Past Week, Past Month, Past Year and All Time in place of This
Week, This Month and This Year: the last 7, 30 and 365 days up to today. Early in a week or a
month the calendar periods held a day or two of plays.

## Decision

- **Whole local days.** Past Week, Past Month and Past Year run from midnight of the first of
  the last 7, 30 or 365 local days to tomorrow's midnight, today included. A day of 23 or 25
  hours counts as one day, and a bar of a day is a whole day, as before. Counting back from the
  moment of reading instead would cut the first day's bar in two.
- **The same cases and the same saved text.** `StatsPeriod.week`, `.month` and `.year` take the
  new spans and titles; the saved source (`stats:week`), the command line's `--period week` and
  its JSON keep their words. Every reader of a period gets the span from one place, so the
  table under the panel, the reader and the command line agree.
- **Year in Review from Past Year** opens the year today is in, as it did from This Year; a past
  year is in the year menu, which stays as it is.
- **A saved list's name** for a rolling period is its days ("Top Artists, Oct 8 – Nov 6, 2026",
  "Nov 7, 2025 – Nov 6, 2026"), not the year its first day is in; a chosen year's is the year.

- **The totals fill their row.** Where the totals share a row with Plays per Day (six columns or
  more), the flow makes them as tall as the row's tallest card, and the figures go into two rows
  of three, each row in the middle of its half; on a row of their own they keep 92 points and
  one row. A card says whether it fills its row, so the rule isn't tied to the two cards' places.

## Alternatives considered

- **The last 7 × 24 hours.** Rejected: the first bar would be part of a day, and a period read at
  09:00 would differ from one read at 21:00 in a way the bars don't show.
- **New case names (`pastWeek`) and saved text.** Rejected: nothing reads the old meaning, and
  the words still say how long the period is.
- **Disabling Year in Review on Past Year.** Rejected: the button would go dim on a period the
  owner uses for the current year's listening, and the year menu still shows the others.

## Consequences

The bars of Past Year are weeks cut at its ends, so its first and last bars are part weeks. A
period's report costs what the calendar period's did: the same two scans over a span of the
same length or close to it.
