# 0210. Requeuing a damaged download

- **Date:** 2026-11-15
- **Status:** accepted
- **Amends:** [0200](0200-upgrading-to-flac-automatically.md) (a tagging error stays for the
  owner)
- **See also:** [0146](0146-staged-tag-writes.md) (the tag run), music-recommender's ADR 0023
  (requeue and tried peers)

## Context

The owner (2026-11-15): "downloads that become staged but have errors should automatically be
retried with a different user/files". The Downloads window showed six staged jobs tagged
Error. The service's reasons said only one was a broken download, a file that doesn't start
like any audio format. The other five were the player's own bugs: two peers' FLACs carried a
Vorbis `TIPL` comment that the writer refused to clear, and three were FLACs with an ID3v2 tag
in front, which the reader took for MP3s. Retrying those would have thrown away good copies
and failed the same way on every peer. Both bugs are fixed in the same branch. The owner
chose to requeue only a copy whose files are broken, and to do it for every download, not just
Upgrade to FLAC Automatically's.

## Decision

**Damaged** means a staged file was read and isn't audio the reader knows: empty, of no format
it reads, or malformed (`MetadataError` kinds `unrecognizedFormat` and `malformed`). A file
that can't be opened, a missing file, one at a size the service didn't stage, a feature the
reader lacks (`unsupported`), a release missing from the catalog and a failed tag write aren't.
Another peer's copy wouldn't change any of those, and a share that drops mid-run mustn't
discard a download.

**The tag run requeues it.** The coordinator on the Mac that tags reports the error with its
reasons, as before, gives up its lease, then sends `requeue`. The service deletes the staged
copy and searches again without the peers the job tried; finding none, it goes `not_found`,
which for an automatic upgrade is a miss (ADR 0200). The job's import ledger is forgotten, as
the upgrader does when it requeues, since the new copy is staged in the same `job-<id>`
folder. A requeue the service doesn't answer is sent again at each poll while the job is
staged; one it refuses, held by a Mac or moved on, is left with its error for the owner and
said in the window's problems. The set waiting is kept in memory, so after a relaunch a job
still waiting keeps its error for the owner.

## Alternatives considered

- **Requeuing every tagging error, as asked.** Rejected with the owner: five of the six errors
  were the player's bugs, and a release missing from the catalog fails for every peer.
- **Deciding from the reasons' text, in the upgrader's pass.** Rejected: the reasons are lines
  for the window, and matching their words would break when one is reworded. The run knows
  what failed when it fails.
- **Requeuing instead of reporting the error.** Rejected: if the service didn't answer, the job
  would be left `running` with no lease and tagged again at every poll, and the owner would
  never see why.

## Consequences

- A broken copy no longer waits for the owner: the download goes on from another peer.
- If the reader wrongly calls a good file malformed, as it did the FLACs with an ID3 tag, each
  peer's copy is thrown away until none is left. The reasons stay in the log and the service's
  history.

## AGENTS.md

The music files bullet in Boundaries says that the tag run requeues a staged download whose
copy is damaged, whose staged copy the service deletes, and links here.
