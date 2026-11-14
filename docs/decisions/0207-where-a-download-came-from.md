# 0207. Where a download came from

- **Date:** 2026-11-14
- **Status:** accepted
- **See also:** [0147](0147-moving-downloads-into-the-library.md) (Approve),
  [0200](0200-upgrading-to-flac-automatically.md) (Never Upgrade, the other record kept by
  release), [0205](0205-recommendations-in-the-player.md) (Recommendations' Download…),
  [0038](0038-sync-logs.md) (the sync logs)

## Context

The owner wants to see new music that came from recommendations in a smart playlist:
"Download Source is Recommendation, Date Added in the last 90 days". It has to work on every
Mac that shares the library, and survive an index rebuild.

Nothing recorded it. Recommendations' Download… queued its albums as `manual` jobs, though
music-recommender's `POST /v1/downloads/create` takes `source: "recommendation"`. And the
import ledger, `import_steps`, is deleted once a job is imported, so nothing durable said where
an imported album came from.

## Decision

**The job says it.** `JobOrder.recommendation(policy)` sends `source: "recommendation"` with
`upgrade: null` and the policies a manual job takes. The Recommendations window's choices
order it, a whole-library list and a seed album's or artist's alike. Every other queue is as it
was.

**A part of its own.** `download_sources (release_id, source, imported_seconds)`, by Discogs
release id, in the `downloadSources` schema part, so a rebuild of the index part leaves it and
no scan has to refill it. `source` is `recommendation` or `manual`.

**Written at import.** `ImportRun` writes the row in the transaction that queues the job's
`imported` report, after its files are in the library, so Approve, Approve Safe Matches
Automatically and Upgrade to FLAC Automatically all write it, and a resumed run writes it once.
The row is keyed by the release the files carry: the one the tagger tagged them as, where it
did (ADR 0178), else the job's.

- **The first import wins.** A later job of the same release leaves the row as it is.
- **An upgrade records nothing of its own**: the album came from wherever it came from first.
  When it replaces files of another release id that has a row, the new release id gets that
  row's source and time. An upgrade kept as a new album with Keep Both records nothing.
- A manual or recommendation job that replaces files of another release with a row takes that
  row's source too, for the same reason.

**Synced.** A `downloadSource` event, `{"release", "source", "at"}`, is logged with each row
this Mac writes. A merge keeps each release's earliest import, a tie on the time going to the
source that sorts first, so every Mac ends with the same row. A source this build doesn't know
is a problem with its line, reported as an unknown player is, and the rest of the log is read.
A rebuild of the sync part reads every log from the start (ADR 0038), which fills the table
again; a snapshot restore brings the table back with the index.

**The smart field.** Download Source, a text field: `Recommendation`, `Manual`, or empty for a
track whose release has no row or that carries no release id. It takes the text comparisons,
whatever the case of the typed value. It joins on the track's `discogs_release_id`, text,
against the integer key, which SQLite compares as a number, so `42` finds release 42 and `42x`
none. The join is on the key, so SQLite leaves it out of every query that doesn't use the
field. No track table column shows it.

## Alternatives considered

- **A column on tracks.** Rejected: a rebuild of the index part drops it, and a scan can't
  refill it from the files.
- **Writing it into the files' tags.** Rejected: the files are written only by the tag writer
  for a tag edit the owner confirmed (AGENTS.md).
- **Filling it in for older jobs.** Rejected: every job before this was sent as `manual`, so
  the service can't tell the recommended ones apart.
- **Keyed by album or track row ids.** Rejected: they change with an index rebuild.
- **The latest import winning**, as ratings do. Rejected: a later manual download of a
  recommended album would hide where it first came from.

## Consequences

- Albums downloaded from recommendations before this build read as Manual or as nothing.
- A rebuild of the `downloadSources` part alone, when its SQL changes, empties it, and the
  logs already read don't fill it again.
- music-recommender's `docs/api.md` still says nothing sends `recommendation`; the player now
  does.
