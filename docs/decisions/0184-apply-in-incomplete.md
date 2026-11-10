# 0184. Apply in Incomplete

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0131](0131-discogs-matching.md) (Incomplete albums checked by hand),
  [0152](0152-one-to-one-matches-discogs.md) (no Apply to All in Incomplete)

## Context

The owner asked, on 2026-11-10, for Apply in the Incomplete tab. Many of the Incomplete
albums with the highest confidence are there only because their files are out of the
release's order, and the window already pairs each file with its track (ADR 0155). With
several albums selected (ADR 0183) the owner can choose which of them to write, as in the
other tabs. Until now an Incomplete album could be written only one at a time, through View
Changes.

## Decision

**Incomplete gets Apply like Exact, Likely and Matched:** Apply to All in Incomplete, or
Apply to N Selected with several albums selected. Each file is written as the window shows it
paired, the same way View Changes → Apply writes a single album, so the tab gets no new rule
for what is written. A file with no track gets only the album-wide fields, as it does in
Likely. The one confirmation still gives the counts before anything is written, and rejected
albums are left out.

No Candidate still has no Apply: its albums have no release.

## Alternatives considered

- **Apply to Selected only, with no Apply to All in Incomplete.** Every Incomplete album
  needs a look first, but the owner can select all and reject the bad ones, or select the
  good ones. Another rule for one tab would be harder to learn than one button that works the
  same in every tab.
- **Scoring a reordered album as Likely.** Rejected in ADR 0155: it changes the shared
  matching rules, and files out of order usually mean their track numbers are wrong, which
  the owner should see.

## Consequences

- A click on Apply to All in Incomplete can write releases with another track count, or
  pairings the matcher guessed. The confirmation is the one check before the write, and Edit
  > Undo Tag Edit puts the files back.
