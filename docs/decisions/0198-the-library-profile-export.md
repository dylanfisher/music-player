# 0198. The library profile, exported to a file

- **Date:** 2026-11-10
- **Status:** accepted; each album's `key`, `last_played` and `skips` added by
  [0206](0206-rediscover.md) (phase 86.1)
- **See also:** [0129](0129-custom-tag-fields.md) (an album's release id),
  [0131](0131-discogs-matching.md) (the matcher's albums),
  [0144](0144-the-service-token.md) (the service token),
  [0145](0145-the-recommender-client.md) (the client)

## Context

music-recommender's community sync fetches the Discogs rating and have/want counts of the
library's tagged releases, and later scores recommendations from the library. It reads the
library as a profile, a JSON shape in its `docs/api.md` (section Profile), which
`music-recommender profile load <file>` reads until the service has a route for it. The player
had no way to write one. The owner asked for an export now, so the sync can start on the
tagged albums while the service's catalog and scoring are built, and asked to leave the album
rating out.

## Decision

- **File > Export Library Profile…** writes the profile to a file the user picks in a save
  panel, read from the index alone on a connection of its own. The owner copies it to mbp2021
  and runs `profile load` there. Nothing is sent over the network.
- **An album** is an album in the index; tracks without one aren't sent. Its tracks go in disc
  and track order, as the Discogs matcher reads them (ADR 0131), each length rounded to whole
  seconds.
- **The artist** is the album artist, else the track artist, else `variousArtists`, the name
  the Artist pane lists such a compilation under, since the service requires one.
- **The release id** is the one every track carries, when it's a positive number, as ADR 0129
  calls an album matched. An album whose tracks disagree or lack one, or carry text, goes with
  `null`, so the sync doesn't fetch a release the album may not be.
- **Catalog numbers and barcodes** are the distinct values the tracks' tags hold, in track
  order. **Plays** are the tracks' counted plays summed, as the play count column shows them;
  **loved** counts the liked tracks.
- **No rating.** The player rates tracks, not albums, and the field is optional, so it's left
  out until the owner decides what an album's rating is.

## Alternatives considered

- **Sending it to the service.** Rejected for now: the service has no profile route yet (its
  phase 7.1). When it does, the request sends this same `LibraryProfile`.
- **The mean of the rated tracks as the album's rating.** Left for the owner, who asked for no
  rating yet.

## Consequences

- The profile is as fresh as its last export; the owner exports again after tagging more
  albums.
