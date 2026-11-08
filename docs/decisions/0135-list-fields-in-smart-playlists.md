# 0135. Whole values of a list field in smart playlists

- **Date:** 2026-11-07
- **Status:** accepted
- **See also:** [0128](0128-discogs-survey.md) (how YATE writes genres, styles and labels),
  [0031](0031-album-artist-and-metadata-columns.md) (the tag columns and smart fields)

## Context

YATE writes a release's styles to `MOOD` as a list (`Dub Techno, House, Techno`) and the owner's
`GENRE` as `{genre} - {styles}` (`Electronic - Dub Techno, House, Techno`, ADR 0128). A smart
playlist of one style can't be made with the text comparisons: "Mood contains Techno" also
matches `Dub Techno`, and "is" matches only a single style. The owner asked on 2026-11-07 for a
rule that compares each value of the list whole (51.20).

## Decision

- **Two comparisons,** "has" and "doesn't have" (`SmartComparison.has`, `.doesNotHave`), on the
  text fields that hold lists: Genre, Mood, Grouping and Publisher (`SmartField.isList`). The
  rule editor lists them only for those fields, and a stored rule that uses them elsewhere is
  refused, as any comparison that doesn't suit its field is.
- **The split:** the value is split on ", " and on " - ", so YATE's genre gives its first genre
  and each style as parts. "Mood has Techno" matches `Dub Techno, Techno` and `Techno, Minimal`,
  not `Dub Techno`. " & " doesn't split: it is part of names (`Stage & Screen`, `Simon &
  Schuster`), so `Columbia & Warp`, as YATE joins labels, is one part.
- **Typed text with a separator** matches those parts in turn: "Genre has Folk, World, &
  Country" matches the Discogs genre that holds commas of its own, and "Mood has Techno,
  Minimal" matches both styles side by side. The cost: "Genre has World" also matches that
  genre, as one of its parts.
- **Folding:** the parts compare as the column sorts. Genre's folded sort name matches whatever
  the case and accents; the other three ignore ASCII case, as their columns do.
- **In SQL:** the indexed column with ", " at both ends and in place of each " - ", against
  `%, <typed>, %` with the typed text's " - " replaced the same way and LIKE's wildcards
  escaped. A missing tag is empty text, so "doesn't have" holds for it. No column or table is
  added. The bench row of four such rules, one per list field, over the 43k fixture tracks is
  15.8 ms (p95) on Apple Silicon against the 50 ms budget of the smart playlist rows.

## Alternatives considered

- **A table of each track's parts,** joined for the rule. Rejected: a second copy of four
  columns to keep in step with every scan, for a rule the string functions answer within the
  budget.
- **Splitting on " & " as well.** Rejected for the names above; a label list is searched with
  "contains".
- **"Is" on a list's parts instead of a new comparison.** Rejected: "Genre is Rock" would no
  longer mean the whole value, as rules imported from Swinsian use it.

## Consequences

A rule on one style works on any file tagged the YATE way, whatever other styles it lists. A
genre or style name with ", " or " - " of its own is matched by typing it whole. The comparisons
are stored by name in the rules' JSON, so a build without them refuses such a playlist.
