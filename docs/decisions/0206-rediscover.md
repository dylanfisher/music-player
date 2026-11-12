# 0206. Rediscover

- **Date:** 2026-11-12
- **Status:** accepted
- **Amends:** [0198](0198-the-library-profile-export.md) (the profile's fields)
- **See also:** [0205](0205-recommendations-in-the-player.md) (the client, its timeouts and
  errors), [0102](0102-listening-stats.md) (a sidebar source with a panel),
  [0105](0105-stats-clicks-filter-and-imported-last-plays.md) (an import's Last Played)

## Context

Phase 86. music-recommender's phase 9 scores the albums the library already has by how long
since they were played, by the community's ratings and haves, and by the owner's loves, and
`POST /v1/rediscover` answers a day's draw of them with reasons and threads (its `docs/api.md`,
Rediscover). It reads three new fields of each album in the profile, `key`, `last_played` and
`skips`, and gives `key` back so the player can find the album. The owner's answers
(2026-11-12): a sidebar source like Listening Stats, with a setting to leave its row out of the
sidebar; albums never played and added recently take part; Not Now is kept by the service; the
profile is sent on its own.

## Decision

### The profile's new fields

- **`key`** is `a` and the index's album id, `a812`. The album id is what the browser's
  Album column selects and the track table lists by, so a reply maps back to its tracks with
  no lookup by name. It changes only when an index rebuild numbers the albums again, which
  the unknown key below covers.
- **`last_played`** is the latest `history` row of the album's tracks: a play recorded here or
  synced from another Mac. `plays.last_played_seconds` isn't read, since an import sets it to
  another app's Last Played, which isn't a play (ADR 0105); an album whose only date is an
  import's goes with `null`, as never played.
- **`skips`** are the tracks' skip counts summed, as the Skips column shows them, imported
  skips included: a skip has no date to tell them apart by.
- Export Library Profile… writes the same fields, so the file stays what is sent.
