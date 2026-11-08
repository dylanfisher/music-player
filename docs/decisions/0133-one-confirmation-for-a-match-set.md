# 0133. One confirmation for a reviewed match set

- **Date:** 2026-11-07
- **Status:** accepted
- **See also:** [0020](0020-tag-writing.md) (tag writing), [0050](0050-remove-from-library.md)
  (the other confirmed change to music files), [0108](0108-faster-tag-writes.md) (batches),
  [0131](0131-discogs-matching.md) (the tiers), [0132](0132-discogs-field-mapping.md) (the
  mapping and the change set)

## Context

AGENTS.md lets `TagWriter` write music files only for a tag edit the user confirmed in the UI.
Get Info confirms one edit for the files it shows. The Discogs tagger writes a release's values
to whole albums, hundreds at once on the owner's library: asking per album would make Apply to
All pointless, and writing without asking would break the boundary. The plan (51.12) asks that
nothing is written before the user confirms, and that a second session doesn't redo the review.

## Decision

- **What the user reviews.** The window shows each album's release and its tracklist beside the
  files, and View Changes shows per file and tag what it holds now against what the mapping
  writes, with a checkbox each. The user can choose another release, remap a guessed album's
  files to tracks, untick a change, or reject the album.
- **One confirmation.** Apply to All in Exact (or Likely) reads the tier's albums' files, leaves
  out the rejected ones and the unticked changes, works out every edit, and asks once with the
  counts of tags, files and albums it changes and the albums it left out and why. That answer
  is the confirmation AGENTS.md asks for, for every file it counts. Apply in one album's View
  Changes asks the same question for that album. Nothing reads as confirmed before the answer:
  the window hands no edit to the writer until then.
- **One undoable edit.** The confirmed edits go to the tag editor's queue as one batch with an
  edit per file (`TagWriter.write(_:progress:)`), after any write queued before, with the status
  bar's progress, the alert for what failed, and Undo Tag Edit putting the whole batch back.
- **Reviews kept.** A rejection and a chosen release are kept in the index by path ID, in a
  schema part of their own (`discogs_reviews`), so they outlast an index rebuild as the loved
  tracks do. Matching takes a chosen release as the album's match whatever the others score;
  Apply leaves a rejected album out. Unticked changes and remapped rows last the session only:
  they belong to one mapping and one reading of the files.

## Alternatives considered

- **A confirmation per album.** Rejected: on 1,700 albums it is 1,700 sheets, and a user who
  answers them that fast hasn't reviewed anything more than with one.
- **No confirmation for Exact.** Rejected: an Exact match is the matcher's judgment, not the
  user's, and the tuning allows up to 2% of them to be another release (ADR 0131).
- **A writer of the tagger's own.** Rejected: it would race the tag editor's writes to the same
  files, and Undo Tag Edit wouldn't know it.
- **Reviews in the config file.** Rejected: they're about files, which the index keys, not
  settings, and the config file is the user's to edit.

## Consequences

AGENTS.md's music files boundary points here. Reviews aren't synced between Macs: each Mac's
index keeps its own, as it keeps its own analysis. A rejected album stays rejected until the
user accepts it again, even after its files change.
