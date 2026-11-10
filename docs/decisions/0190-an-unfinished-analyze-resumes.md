# 0190. An unfinished Analyze resumes where it stopped

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0139](0139-the-api-as-a-source-in-matching.md) (the API alone keeps its matches
  when it stops), [0138](0138-the-discogs-api-client.md) (an album's search results are kept
  for one run)
- **See also:** [0189](0189-discogs-covers-kept-on-disk.md) (the covers, kept the same way)

## Context

The owner asked, on 2026-11-10, which other long runs lose their work to a quit or a crash.
Analyze with the Discogs API makes up to three or more paced searches an album, at about 60
requests a minute, so a library of thousands takes hours. Its matches are held in memory until
the run ends. Releases and masters are kept in `discogs_cache`, but searches aren't (ADR 0138),
so a run after a crash searched again for every album. With the API alone, an error that
stopped the run also dropped every album matched so far; Both kept them (ADR 0139).

## Decision

- **A checkpoint, not a cache of searches.** `ApiCandidates.found` keeps what an album's
  searches found in `discogs_cache` as kind `found`, by album ID, with what the searches read
  (`CandidateSearch`: the chosen release, the tagged IDs, barcode, label, catalog number,
  artist and title). A run that finds a kept entry for an album, younger than a day and read
  from the same values, uses it in place of searching. Without a token nothing is searched, so
  nothing is kept.
- **Forgotten when the run finishes.** Once the API pass gets through every album it was
  given, `matchAlbums` removes their entries, so a deliberate Analyze afterwards searches
  again, as ADR 0138 wants. A run stopped by a quit, a crash, Stop or a Discogs error keeps
  them. Only the albums a run covered are forgotten, so a download's auto-tag finishing in the
  meantime leaves a stopped library run's entries alone.
- **A day, at most.** A stopped run is usually run again the same day; past that, a search is
  worth asking again.
- **The API alone keeps its matches.** A `DiscogsAPIError` that stops the run is thrown as
  `APIStoppedMatching` with the albums matched so far, for the API alone as for Both. The
  tagger shows those albums, "Analyzed 1,200 of 4,000 albums in … s; Discogs stopped, so
  Analyze again to match the rest", with the alert.

## Alternatives considered

- **Caching each search's answer for a day.** Rejected: every Analyze would reuse it, so a
  release added to Discogs after a run wouldn't be found for a day even by a deliberate run.
  The checkpoint changes only a run after one that didn't finish.
- **Checkpointing the whole match.** Rejected: the match is scored from the releases, which
  are already kept, and the album's tracks, which a tag edit can change. Scoring again costs no
  request.

## Consequences

- A run after a crash makes no search for an album the stopped run reached; its releases come
  and masters come from the cache, so it costs no request at all.
- A stopped run with the API alone replaces the albums shown with the ones it matched; the
  albums it hadn't reached appear after the next run.
- Changing `discogs_cache`'s SQL comment rebuilds the table once, empty, as any cache part is.
