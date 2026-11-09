# 0157. Looking up a release, and leaving files out of a match

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0130](0130-discogs-catalog.md) (the catalog's keys),
  [0131](0131-discogs-matching.md) (matching), [0133](0133-one-confirmation-for-a-match-set.md)
  (a release chosen), [0139](0139-the-api-as-a-source-in-matching.md) (the API as a source),
  [0146](0146-staged-tag-writes.md) (staged jobs)

## Context

The owner asked for two ways past an album the matcher gets wrong. Look Up Release: search for
a release the matcher didn't find, "using the same local discogs database dump first if
present, and falling back to discogs api". And leaving tracks out: an album holding duplicates
of another release's tracks never matched its release's count, so it couldn't be tagged.

The catalog's keys are folded exact values, indexed for the matcher's lookups: barcode, label
then catalog number, artist then title. A person searching types partial words, a catalog number
without its label, or a title without its artist.

## Decision

**The catalog first, the API when it finds nothing.** Search asks the catalog by release id, by
catalog number on any label, else by artist and title through the matcher's folded keys,
including its artist splits and title variants. Every field given must then hold for each
release found (the artist and title within its own, folded; the catalog number as one of its
labels'). Only when that finds nothing, or there's no usable catalog, is Discogs asked: a release
id needs no token, a search does, and its first releases are fetched as the matcher fetches
them. Nothing is sent before the user clicks Search. Whatever the source setting says, the
catalog comes first, since a search is one person's question and the catalog answers it with no
request.

**No new indexes.** A catalog number alone, and a title alone, read every key, since the keys
are indexed by label first and by artist first. An index for each would change the catalog's
schema identity, which discards every catalog and asks for the dump to be imported again, for a
search a person runs one at a time. The reads stop at 200 releases, and the sheet says when more
were found. If the owner finds them slow on the 2015 MacBook Pro, the indexes are the fix, with
the reimport that comes with them.

**A release from the API is matched with the API.** Choosing a release Look Up found on Discogs
matches the album with Both (or the API, without a catalog) even when the source is the local
catalog, so the release is scored from the cached reply rather than refused as missing.

**Files left out are the session's.** A file unticked in the tracklist is left out of the album:
the album is matched again without it, with the release the user chose if any, and Apply neither
reads nor writes it. What's left out is kept by album for the session, so a new Analyze leaves
the same files out, but isn't written to the index: it marks a problem the owner means to fix
in the library (a duplicate to remove), not a fact about the files, and a column in the index
for it would outlive the problem.

**Not in a staged job.** A staged job's files all move into the library together on Approve
(ADR 0147), and its verdict reads every file back; a file left untagged would read back as a
discrepancy forever. Its release is fixed too, so its tagger has neither Look Up nor the boxes.

**Counts read in the background.** "View 44 Changes…" needs the album's files read. The model
reads the selected album's files 0.3 s after the selection settles, and forgets every count when
an album, the mapping or the choices change. The cover isn't counted, since that would ask
Discogs for the image on a selection.

## Consequences

- Look Up's partial-word search is Discogs's: the catalog matches whole folded values, so a
  part of a title finds nothing there and goes to the API, which needs a token.
- A relaunch starts with every file in; the owner unticks the duplicates again if they are still
  there.
- Moving through the album list reads each album stopped on for 0.3 s, over the NAS too.
