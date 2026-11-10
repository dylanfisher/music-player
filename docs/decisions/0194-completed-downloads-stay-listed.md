# 0194. Completed downloads stay listed for 30 days

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0147](0147-moving-downloads-into-the-library.md) (Approve),
  [0193](0193-approving-safe-matches-unasked.md) (approving unasked),
  [0163](0163-download-progress-and-the-status-item.md) (the window's sections)

## Context

The owner asked for downloads that were staged and then approved, by hand or unasked, to stay
in the Downloads window, sorted at the end, as completed, for 30 days. The window left out
every `imported` job, so an album approved unasked left no trace there.

## Decision

- **The service is the store.** music-recommender keeps a terminal job in its list for 30 days
  after it became terminal, then purges it (its `docs/api.md`), and the player already polls
  every job it lists. So the player keeps nothing of its own: an `imported` job is a row in a
  last section, Completed, newest first like the others, with the state "Completed" and no
  actions.
- **The 30 days are the player's too.** `DownloadRow.completedListedFor` is 30 days from the
  job's `updated_at`, which for an imported job is its import, the service's last change to
  it. A row past it isn't built, so a purge that comes late, or a service that keeps jobs
  longer, doesn't keep it listed.
- **Rejected and cancelled jobs** stay out of the list, as before: neither reached the library.

## Alternatives considered

- **A table of completed jobs in the index.** Rejected: a second copy of what the service
  lists, which would need its own pruning, and a Mac other than the one that imported would
  show nothing.

## Consequences

- A row past its 30 days goes at the next change to the rows, or the service's purge, not to
  the second.
- A Mac that sees a job only after the service purged it never lists it.
