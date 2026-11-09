# 0170. A match's confidence, the Safe tab, and choosing without searching

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0131](0131-discogs-matching.md) (the tiers and the score),
  [0133](0133-one-confirmation-for-a-match-set.md) (Apply to All, a chosen release),
  [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md) (the reasons),
  [0139](0139-the-api-as-a-source-in-matching.md) (the API's cache),
  [0148](0148-the-shared-matching-rules.md) (the rules the golden file pins)

## Context

The tiers say which rule an album's match passed, not how close it came: a Likely album with
one title a letter off reads the same as one with half its titles wrong. The owner asked for a
confidence per album, from the chosen release's score, and for a set of albums safe to apply
without reviewing each: every title the same, the counts and lengths fitting, and "found by
title only" the only reason.

By the matcher's rules that set, read literally, is always empty. An album whose every title is
the same in order, with the same count and every known length agreeing, is Exact unless the
tie-break leaves other releases fitting as well; so every such Likely album says "other
releases fit as well", and also "found by title only" when no id, barcode or catalog number led
to it. An Exact album says no reasons at all.

Choosing a release in Other Releases matched the album again, which in API or Both mode ran
the barcode, catalog number and title searches again, and Discogs's search is never cached.

## Decision

- **The confidence**, a whole percent, is worked out once, when the match is made, from the
  chosen release's score as the window shows it (`MatchConfidence`):
  - Start at 100 times the title fit: the paired files' title similarities over the longer of
    the album's and the release's counts, where a title at least `sameTitle` (0.85) like its
    track's counts 1, as the matcher counts it the same, and a file or track left unpaired
    counts 0.
  - Less 30 times the share of paired files whose length differs from the track's, and 5 times
    the share whose track has no length on Discogs.
  - Less 10 for another count, 10 times the share of files paired out of their place, 5 for a
    tie after the tie-break, 5 for a release found by title only, and 10 for tracks carrying
    different release ids.
  - Clamped to 0–100 and rounded; none for an album with no release scored.

  So Exact found by a barcode is 100, Exact by title only 95, Likely for a tie by title only
  90, one title of three at 0.82 by title 89, two lengths of three off 80, and two bonus files
  on a three-track release 45. The weights live in `MatchConfidence`, not `MatchThreshold`,
  which the golden file shared with music-recommender checks. Ranking, tiers and reasons don't
  change. A file dragged to another track keeps the confidence and the reasons the matcher gave.
  The album list's column is headed "Match", short for the 280 pt list, and shows "92%".
- **The Safe tab**, after Likely, lists the Likely albums whose reasons are only "other releases
  fit as well" and "found by title only", at least one of them: those whose release fits every
  title in order, the count and every known length. The tie is allowed because, without it, the
  set is empty; the releases tied fit the files equally and differ only in pressing details.
- **A tab, not a filter.** The window already scopes Apply to All by tab, so Apply to All in
  Safe works as on Exact and Likely with no new control. Safe is a view: Likely still lists its
  albums, so each album keeps one tier and the counts of the tier tabs still add up.
- **Choosing loads one release.** Choose loads the chosen release, from the catalog unless the
  source is the API alone, else through the API's cache (`release(id:)`), and scores it alone,
  tiered by its own score as a chosen release always was. The other candidates are the previous
  match's, with the release it had chosen scored again among them, and the chosen release keeps
  how the run found it. No search runs. A full Analyze still matches a chosen release with the
  album's searches, and leaving a file out still matches the album again.

## Alternatives rejected

- **Safe as "found by title only" alone.** Empty under the matcher's rules, as above.
- **Moving the Safe albums out of Likely.** It would make the tiers two things, the matcher's
  verdict and a view, and the staged tagger and the tools that count tiers would read the
  second.
- **The confidence as `rank` scaled to 100.** `rank` counts titles at their raw similarity, so
  an album whose every title is the same after folding but differs a little before would lose
  points the matcher doesn't hold against it, and lengths unknown would count half.

## Consequences

The owner can apply the Safe tab's albums with one confirmation and review Likely's rest. A
chosen release is no longer left out by the video skip, which only applied to releases no one
chose. Phase 65's test with a counting stand-in holds Other Releases, a cover and Choose to no
request but the cover's image.
