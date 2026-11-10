# 0173. A colon in a library folder name becomes a dash

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0124](0124-drop-files-and-the-library-folder.md) (the layout's safe names)

## Context

The owner, after organizing the library on 2026-11-09, found the album "Éthiopiques 22: More
Vintage! 1972-1974" in a folder named `Éthiopiques 22_ More Vintage! 1972-1974`. ADR 0124 turned
every character a volume or a share refuses into `_`. A colon can't stay: SMB servers refuse it,
and Finder shows a colon in a name as `/`. Most colons in titles mark a subtitle, and `_` reads
as a gap there.

## Decision

`safeName` turns a colon followed by a space into ` - `, along with any spaces before it, and any
other colon into `-`: `22: More` becomes `22 - More`, and `(5:40)` becomes `(5-40)`. The other
refused characters, `/ \ * ? " < > |`, still become `_`. Files already organized under the old
names keep them until a tag edit with Keep Files Organized on, or Organize Selected Files,
renames them (ADR 0164).

## Alternatives considered

- **A space.** Rejected: `Éthiopiques 22 More Vintage!` runs the title and subtitle together.
- **` - ` for every colon.** Rejected: a time reads as `5 - 40`.
- **A colon lookalike** (`꞉` U+A789, `：` U+FF1A). Rejected: it looks right but is hard to type in
  Terminal, and a search for `22:` doesn't find it.

## Consequences

Every organized album or track with a colon gets a new destination, so the next Organize
Selected Files over the library renames them, and the folders they leave are removed when empty.
A folder named `A - B` by its tags and one named `A: B` now go to the same place; the second to
arrive is listed as taken, as any collision is.
