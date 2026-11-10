# 0178. A staged download can be tagged as another release, which the player keeps until the service can

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0146](0146-staged-tag-writes.md) (the staged tagger's release was fixed)
- **See also:** [0145](0145-the-recommender-client.md) (the service's contract),
  [0147](0147-moving-downloads-into-the-library.md) and
  [0169](0169-approve-at-once-and-manual-upgrades.md) (Approve),
  [0170](0170-match-confidence-and-the-safe-tab.md) (choosing a release)

## Context

A download is queued for one Discogs release. When the files the service found are another
edition, such as one with a bonus track, the tag run reports a discrepancy, and the tagger
opened from Downloads could only write the queued release's tags: it refused any other with
"this album was downloaded for release N; reject it in Downloads to queue another". The owner
asked to fix the discrepancy by choosing the release the files are.

music-recommender lists each job with the release it was queued for, and has no call to change
it. The owner is having one added separately, probably `POST /v1/downloads/release` with `id`
and `release_id`, allowed while the job is `staged` or failed at `tag`. The player can't call a
route that doesn't exist.

## Decision

**The staged tagger chooses as the library's does.** Other Releases… and Look Up… choose any
release in the local catalog. Look Up searches the catalog only, since every staged match is
made from it (ADR 0146), and a release only the API has couldn't be matched. The release chosen
is kept for the tagger's session; Analyze and the match use it. Apply is confirmed as any
tagger write is, writes through `StagedWriter` in the staging folder, and hands the verdict to
Downloads with the release it wrote. Reject still points to Downloads, which deletes the staged
folder.

**The player keeps the release with the staged job.** `DownloadsCoordinator.resolved` records
it in this Mac's import ledger as a `retagged` step, the job's folder as its path and the
release in `destination`, before it reports the verdict. A release that is the queued one
removes the step. The step goes with the job's other steps once it's imported. From then on:

- `stagedJob(_:)` tags with the recorded release, so the tagger opened again, or a tag run
  that takes the job over, matches the files as what they were written as.
- The Downloads row names it while the job is staged in that folder and the service lists
  another release (`TaggedRelease.differs(for:)`): the Tagging cell adds "another release", and
  its tooltip and the album's say which release was queued, which the files are tagged as, and
  that only this Mac knows. The Approve sheet's subtitle names both.

**Approve is unchanged.** It still needs a staged job reported clean under this Mac's review
claim. The library album it replaces, for an upgrade or a job found by its release (ADR 0169),
is still the queued release's: those are the library's files, which carry the queued release
or were found by its name, and the files the service downloaded were sent for it. The old
files' positions are placed on the queued release, as the service's positions of the new files
are, so the upgrade's mapping compares like with like.

**The service call, when it exists.** `RecommenderClient` gets the route beside `retry`, and
`DownloadsService` a closure for it. `resolved` calls it after recording the release and before
the tagging report, while the job is still staged. Once the service lists the job with the new
release, `differs(for:)` is nil and the row stops naming it; the ledger step can stay, since it
then says nothing the service doesn't. Until then, a refusal of the call needs no handling
here.

## Alternatives considered

- **Rejecting and queueing the other release.** Rejected by the owner's request: the files
  already downloaded are the other release, and a new search may not find them again.
- **Keeping the release in the tagging report's reasons.** Rejected: the contract keeps
  `reasons` empty for a clean run, and the service would show it as a problem.
- **Reading the release id from the staged files' tags for each row.** Rejected: the window
  would read files on the share at every poll, and an uploader's release id looks the same.
- **Matching Approve's replaced album by the new release.** Not now: the owner queued the job
  for the queued release, often to replace an album that carries it. The ADR 0169 search can
  take the new release too if the owner finds a case where it matters.

## Consequences

- A discrepancy from another edition is fixed in the tagger, not by a new download.
- Only the Mac that tagged the files knows their new release until the service records it.
  Another Mac's Downloads row and Approve sheet name the queued release, and its tagger, opened
  on the job, matches the queued one; the files' tags are still what was written.
- The music files rule is unchanged: the write is a confirmed tagger write, through
  `TagWriter`, inside the staging folder (ADR 0146).
